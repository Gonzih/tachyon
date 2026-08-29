import Foundation

/// OpenRouter — the first pure-config provider: no harness install to detect,
/// just an API key the user pastes into Settings (stored in Tachyon's own
/// Keychain item, never UserDefaults).
///
/// `GET /api/v1/auth/key` reports the key's cumulative `usage` (USD) and an
/// optional `limit`. A limited key is a real bounded window → percent ring.
/// An unlimited key gets monthly spend — cumulative usage minus a month-start
/// baseline Tachyon snapshots locally — measured against the budget setting.
actor OpenRouterProvider: UsageProvider {
    nonisolated let id = "openrouter"
    nonisolated let displayName = "OpenRouter"
    nonisolated let shortName = "OpenRouter"
    nonisolated let glyph = ProviderGlyph.openrouter
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let category: ProviderCategory = .infrastructure
    nonisolated let about: String? =
        "Spend across every model routed through your OpenRouter key — pay-as-you-go or key-limited."
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
        do {
            let result = try await Usage.get(Self.keyURL, headers: [
                "Authorization": "Bearer \(key)",
            ])
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

            var windows: [UsageWindow] = []
            let primary: UsageWindow
            if let limit, limit > 0 {
                // A limited key is a genuine bounded window.
                primary = UsageWindow(label: "Key limit", percentUsed: usage / limit * 100, resetsAt: nil)
                windows.append(primary)
                windows.append(UsageWindow(
                    label: "This month", spendUSD: monthSpend,
                    budgetUSD: Settings.moneySetting("budget.monthly", provider: id),
                    resetsAt: nil))
            } else {
                primary = UsageWindow(
                    label: "This month", spendUSD: monthSpend,
                    budgetUSD: Settings.moneySetting("budget.monthly", provider: id),
                    resetsAt: nil)
                windows.append(primary)
            }
            windows.append(UsageWindow(label: "All time", spendUSD: usage, resetsAt: nil))

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
