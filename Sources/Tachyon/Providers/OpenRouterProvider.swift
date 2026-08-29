import Foundation

/// OpenRouter — the first pure-config provider: no harness install to detect,
/// just an API key the user pastes into Settings (stored in Tachyon's own
/// Keychain item, never UserDefaults).
///
/// Two endpoints, two scopes:
/// - `GET /api/v1/credits` — account-wide `total_usage` against prepaid
///   `total_credits`. The main metric: a real bounded window → percent ring,
///   "$100.17 of $100". Credits never refresh, so no reset time.
/// - `GET /api/v1/auth/key` — THIS key's cumulative `usage` (USD) and optional
///   `limit`. A limited key is a bounded window; otherwise monthly spend —
///   cumulative usage minus a month-start baseline Tachyon snapshots locally —
///   measured against the budget setting.
actor OpenRouterProvider: UsageProvider {
    nonisolated let id = "openrouter"
    nonisolated let displayName = "OpenRouter"
    nonisolated let shortName = "OpenRouter"
    nonisolated let glyph = ProviderGlyph.openrouter
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let category: ProviderCategory = .infrastructure
    nonisolated let about: String? =
        "Account credits plus this key\u{2019}s spend across every model routed through OpenRouter."
    nonisolated let settings: [ProviderSetting] = [
        ProviderSetting(
            key: "apiKey",
            title: "API key",
            help: "Stored in your Keychain. Create one at openrouter.ai/keys.",
            kind: .secret(placeholder: "sk-or-…")
        ),
        ProviderSetting(
            key: "budget.monthly",
            title: "Monthly budget",
            help: "Colors the ring against a spend ceiling when the key has no hard limit.",
            kind: .money(defaultValue: nil)
        ),
    ]

    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/auth/key")!
    private static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    /// Kept so transient failures degrade to `.stale`.
    private var lastGood: (snapshot: UsageSnapshot, at: Date)?

    // MARK: - Presence

    /// Config-based: "installed" the moment a key exists; before that it shows
    /// as needing setup so the Settings pane stays reachable.
    func detect() async -> ProviderPresence {
        Settings.secretSetting("apiKey", provider: id) != nil
            ? .ready
            : .notSignedIn("Add API key in Settings")
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let key = Settings.secretSetting("apiKey", provider: id) else {
            return .authError("Add API key in Settings")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        do {
            let result = try await Usage.get(Self.keyURL, headers: headers)
            if result.status == 401 || result.status == 403 {
                return .authError("API key rejected — check Settings")
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("openrouter HTTP \(result.status)")
                if let last = lastGood { return .stale(last.snapshot, asOf: last.at) }
                return .unavailable
            }

            let data = JSONValue.parse(result.body)["data"]
            guard let usage = data["usage"].double else {
                Log.provider.error("openrouter decode produced no usage")
                return .unavailable
            }
            let limit = data["limit"].double
            let isFree = data["is_free_tier"].bool ?? false

            // "This month" is Tachyon's measurement window, not an OpenRouter
            // reset — credits are prepaid and never refresh. No reset time.
            let monthSpend = Self.monthSpend(cumulative: usage)

            // Account credits — the main metric. Best-effort second call;
            // the key windows must survive its failure.
            var creditsWindow: UsageWindow?
            if let credits = try? await Usage.get(Self.creditsURL, headers: headers),
               (200..<300).contains(credits.status) {
                let account = JSONValue.parse(credits.body)["data"]
                if let total = account["total_credits"].double,
                   let used = account["total_usage"].double, total > 0 {
                    creditsWindow = UsageWindow(
                        label: "Credits", spendUSD: used, budgetUSD: total, resetsAt: nil)
                }
            }

            // Build in ring-priority order: account credits, then a hard key
            // limit, then the budget-measured month — windows[0] is the ring.
            var windows: [UsageWindow] = []
            if let creditsWindow {
                windows.append(creditsWindow)
            }
            if let limit, limit > 0 {
                // A limited key is a genuine bounded window.
                windows.append(UsageWindow(
                    label: "Key limit", percentUsed: usage / limit * 100, resetsAt: nil))
            }
            windows.append(UsageWindow(
                label: "Key · this month", spendUSD: monthSpend,
                budgetUSD: Settings.moneySetting("budget.monthly", provider: id),
                resetsAt: nil))
            windows.append(UsageWindow(label: "Key · all time", spendUSD: usage, resetsAt: nil))
            let primary = windows[0]

            let snapshot = UsageSnapshot(
                primary: primary,
                windows: windows,
                asOf: Date(),
                detail: isFree ? "Free tier" : nil
            )
            lastGood = (snapshot, Date())
            return .ok(snapshot)
        } catch {
            Log.provider.error("openrouter request failed: \(error.localizedDescription, privacy: .public)")
            if let last = lastGood { return .stale(last.snapshot, asOf: last.at) }
            return .unavailable
        }
    }

    // MARK: - Monthly baseline

    /// auth/key reports lifetime spend; month spend = cumulative − the first
    /// reading seen this month. The baseline self-heals if usage ever reads
    /// lower than it (key rotated or credits refunded).
    static func monthSpend(cumulative: Double) -> Double {
        let monthKey = "provider.openrouter.baseline.month"
        let valueKey = "provider.openrouter.baseline.usage"
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: Date())
        let thisMonth = "\(components.year ?? 0)-\(components.month ?? 0)"

        let defaults = Settings.defaults
        if defaults.string(forKey: monthKey) != thisMonth
            || (defaults.object(forKey: valueKey) as? Double).map({ $0 > cumulative }) == true {
            defaults.set(thisMonth, forKey: monthKey)
            defaults.set(cumulative, forKey: valueKey)
        }
        let baseline = defaults.object(forKey: valueKey) as? Double ?? cumulative
        return max(0, cumulative - baseline)
    }
}
