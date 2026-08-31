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

    private struct Credential: Sendable {
        let key: String
        let revision: Int
    }

    private enum CredentialLoad {
        case missing
        case changedDuringRead
        case loaded(Credential)
    }

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
        switch credential() {
        case .missing:
            return .authError("Add API key in Settings")
        case .changedDuringRead:
            return .unavailable
        case .loaded(let credential):
            return await snapshot(using: credential)
        }
    }

    func reading() async -> ProviderReading {
        switch credential() {
        case .missing:
            return ProviderReading(
                state: .authError("Add API key in Settings"),
                accountFingerprint: nil
            )
        case .changedDuringRead:
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        case .loaded(let credential):
            let state = await snapshot(using: credential)
            guard !Task.isCancelled else {
                return ProviderReading(state: .unavailable, accountFingerprint: nil)
            }
            return ProviderReading(
                state: state,
                accountFingerprint: Self.credentialFingerprint(
                    key: credential.key,
                    revision: credential.revision
                )
            )
        }
    }

    private func credential() -> CredentialLoad {
        let revisionBeforeRead = Settings.secretRevision("apiKey", provider: id)
        guard let key = Settings.secretSetting("apiKey", provider: id) else {
            return .missing
        }
        let secretRevision = Settings.secretRevision("apiKey", provider: id)
        guard revisionBeforeRead == secretRevision else {
            // The setting changed between the two reads. A refresh already
            // follows the Settings commit, so do not mix key generations.
            return .changedDuringRead
        }
        return .loaded(Credential(key: key, revision: secretRevision))
    }

    private func snapshot(using credential: Credential) async -> ProviderState {
        let headers = ["Authorization": "Bearer \(credential.key)"]
        do {
            let result = try await Usage.get(Self.keyURL, headers: headers)
            if result.status == 401 || result.status == 403 {
                return .authError("API key rejected — check Settings")
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("openrouter HTTP \(result.status)")
                return .unavailable
            }

            let data = JSONValue.parse(result.body)["data"]
            guard let usage = data["usage"].double else {
                Log.provider.error("openrouter decode produced no usage")
                return .unavailable
            }
            let limit = data["limit"].double
            let isFree = data["is_free_tier"].bool ?? false

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

            guard credential.revision == Settings.secretRevision("apiKey", provider: id) else {
                // Discard an in-flight response from the previous key rather
                // than recording its spend as the new key's baseline.
                return .unavailable
            }

            // "This month" is Tachyon's measurement window, not an OpenRouter
            // reset — credits are prepaid and never refresh. No reset time.
            let monthSpend = Self.monthSpend(
                cumulative: usage,
                secretRevision: credential.revision
            )

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

            return .ok(UsageSnapshot(
                primary: primary,
                windows: windows,
                asOf: Date(),
                detail: isFree ? "Free tier" : nil
            ))
        } catch {
            Log.provider.error("openrouter request failed")
            return .unavailable
        }
    }

    static func credentialFingerprint(key: String, revision: Int) -> String? {
        guard !key.isEmpty else { return nil }
        return OpaqueAccountIdentity.fingerprint(
            namespace: "openrouter-credential",
            components: [key, String(max(0, revision))]
        )
    }

    // MARK: - Monthly baseline

    /// auth/key reports lifetime spend; month spend = cumulative − the first
    /// reading seen this month. A non-secret credential revision prevents one
    /// key's baseline from leaking into another key's spend. The baseline also
    /// self-heals if cumulative usage falls (refund or upstream reset).
    static func monthSpend(
        cumulative rawCumulative: Double,
        secretRevision rawRevision: Int = 0,
        now: Date = Date(),
        defaults: UserDefaults = Settings.defaults
    ) -> Double {
        guard rawCumulative.isFinite else { return 0 }
        let cumulative = max(0, rawCumulative)
        let secretRevision = max(0, rawRevision)
        let monthKey = "provider.openrouter.baseline.month"
        let valueKey = "provider.openrouter.baseline.usage"
        let revisionKey = "provider.openrouter.baseline.secretRevision"
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: now)
        let thisMonth = "\(components.year ?? 0)-\(components.month ?? 0)"

        let storedRevision = defaults.object(forKey: revisionKey).map { _ in
            defaults.integer(forKey: revisionKey)
        } ?? 0
        let baseline = defaults.object(forKey: valueKey) as? Double
        if storedRevision != secretRevision
            || defaults.string(forKey: monthKey) != thisMonth
            || baseline == nil
            || baseline.map({ !$0.isFinite || $0 > cumulative }) == true {
            defaults.set(thisMonth, forKey: monthKey)
            defaults.set(cumulative, forKey: valueKey)
        }
        defaults.set(secretRevision, forKey: revisionKey)
        let currentBaseline = defaults.object(forKey: valueKey) as? Double ?? cumulative
        return max(0, cumulative - currentBaseline)
    }
}
