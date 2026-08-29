import Foundation
import SQLite3

/// Oh My Pi usage — the first *spend* provider. omp computes its own cost and
/// records it in `~/.omp/agent/agent.db` (`usage_cost_history`: recorded_at,
/// provider, account_key, cost_usd), so Tachyon just sums rows per period.
/// No pricing tables, no token math. Free-model users legitimately sit at $0.
actor OmpProvider: UsageProvider {
    nonisolated let id = "omp"
    nonisolated let displayName = "Oh My Pi"
    nonisolated let shortName = "Oh My Pi"
    nonisolated let glyph = ProviderGlyph.omp
    /// Local database read — cheap, but nothing moves fast.
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let about: String? =
        "Quota windows and per-turn cost from Oh My Pi\u{2019}s own database — covers every account it routes."
    nonisolated let settings: [ProviderSetting] = [
        ProviderSetting(
            key: "budget.monthly",
            title: "Monthly budget",
            help: "Colors the ring against a spend ceiling. Leave empty for a plain dollar readout.",
            kind: .money(defaultValue: nil)
        ),
    ]

    // MARK: - Paths

    private static var home: String {
        Usage.env("OMP_HOME") ?? Usage.homePath(".omp")
    }

    private static var dbPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("agent/agent.db").path
    }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        guard Usage.fileExists(Self.home) else { return .notInstalled }
        guard Usage.fileExists(Self.dbPath) else { return .notSignedIn("Run `omp` once to initialize") }
        return .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let sums = Self.readSpend() else {
            Log.provider.error("omp agent.db unreadable")
            return .unavailable
        }
        let limits = Self.readLimits()

        // omp records bounded quota windows for subscription accounts in
        // usage_history — when they exist, the worst active one is the ring
        // and the pill behaves exactly like a bounded provider. Spend rows
        // ride along either way.
        // Synthetic measurement periods: the label carries the period; a
        // "Resets…" line would imply a provider quota refresh that does not
        // exist. Only omp-reported bounded windows get reset times.
        let spendToday = UsageWindow(label: "Today", spendUSD: sums.today, resetsAt: nil)
        // The budget attaches HERE, to this one window, at construction —
        // never by matching labels downstream. Breakdown rows stay spend-only.
        let budget = Settings.moneySetting("budget.monthly", provider: id)
        let spendMonth = UsageWindow(
            label: "This month", spendUSD: sums.month, budgetUSD: budget, resetsAt: nil)

        // Primary rule (spec §8.3): real bounded window → budgeted month →
        // today's spend. Real limits beat synthetic ones.
        var windows: [UsageWindow] = []
        let primary: UsageWindow
        if let worst = limits.max(by: { ($0.percentUsed ?? 0) < ($1.percentUsed ?? 0) }) {
            primary = worst
            windows = limits
            windows.append(spendToday)
            windows.append(spendMonth)
        } else if spendMonth.percentUsed != nil {
            primary = spendMonth
            windows = [spendMonth, spendToday]
        } else {
            primary = spendToday
            windows = [spendToday, spendMonth]
        }

        for (provider, amount) in sums.monthByProvider.sorted(by: { $0.value > $1.value }) where amount >= 0.01 {
            windows.append(UsageWindow(
                label: provider.prefix(1).uppercased() + provider.dropFirst(),
                spendUSD: amount,
                resetsAt: nil
            ))
        }

        return .ok(UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: Date(),
            detail: Self.modelDetail()
        ))
    }

    /// Latest bounded window per provider/account/limit from usage_history,
    /// keeping only fresh rows (recorded within 24h or resetting in the
    /// future). email/account_id columns are never read.
    private static func readLimits() -> [UsageWindow] {
        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT provider, COALESCE(window_label, label, limit_id), used_fraction, resets_at, MAX(recorded_at)
            FROM usage_history GROUP BY provider, account_key, limit_id
            """, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var windows: [UsageWindow] = []
        let now = Date()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let providerText = sqlite3_column_text(statement, 0) else { continue }
            let provider = String(cString: providerText)
            let label = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "Window"
            let fraction = sqlite3_column_double(statement, 2)
            let resets = Self.flexibleDate(statement, column: 3)
            let recorded = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))

            let fresh = now.timeIntervalSince(recorded) < 24 * 3600
                || (resets.map { $0 > now } ?? false)
            guard fresh else { continue }

            windows.append(UsageWindow(
                label: "\(provider.prefix(1).uppercased() + provider.dropFirst()) · \(label)",
                percentUsed: fraction * 100,
                resetsAt: resets
            ))
        }
        return windows
    }

    /// resets_at may be epoch seconds, epoch millis, or ISO8601 text.
    private static func flexibleDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return ISO8601DateFormatter().date(from: String(cString: text))
        default:
            return nil
        }
    }

    // MARK: - Database

    private struct Spend {
        let today: Double
        let month: Double
        let monthByProvider: [String: Double]
    }

    /// Read-only; a locked database degrades to nil, never blocks.
    private static func readSpend() -> Spend? {
        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let calendar = Calendar.current
        let midnight = Int(calendar.startOfDay(for: Date()).timeIntervalSince1970)
        let monthStart = Int((calendar.dateInterval(of: .month, for: Date())?.start ?? Date()).timeIntervalSince1970)

        func sum(_ query: String, bind: Int) -> Double? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(bind))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_double(statement, 0)
        }

        // recorded_at is unix seconds; COALESCE keeps empty tables at $0
        // rather than failing (a fresh or free-model install has no rows).
        guard let today = sum(
            "SELECT COALESCE(SUM(cost_usd), 0) FROM usage_cost_history WHERE recorded_at >= ?",
            bind: midnight
        ) else { return nil }
        guard let month = sum(
            "SELECT COALESCE(SUM(cost_usd), 0) FROM usage_cost_history WHERE recorded_at >= ?",
            bind: monthStart
        ) else { return nil }

        var byProvider: [String: Double] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "SELECT provider, COALESCE(SUM(cost_usd), 0) FROM usage_cost_history WHERE recorded_at >= ? GROUP BY provider",
            -1, &statement, nil) == SQLITE_OK, let statement {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(monthStart))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) {
                    byProvider[String(cString: name)] = sqlite3_column_double(statement, 1)
                }
            }
        }

        return Spend(today: today, month: month, monthByProvider: byProvider)
    }

    /// Footer: the configured default model, from agent/config.yml.
    private static func modelDetail() -> String? {
        let configPath = URL(fileURLWithPath: home).appendingPathComponent("agent/config.yml").path
        guard let data = FileManager.default.contents(atPath: configPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("default:") {
                let model = trimmed.dropFirst("default:".count).trimmingCharacters(in: .whitespaces)
                // "opencode-zen/nemotron-3-ultra-free" → "nemotron-3-ultra-free"
                return model.split(separator: "/").last.map(String.init)
            }
        }
        return nil
    }
}
