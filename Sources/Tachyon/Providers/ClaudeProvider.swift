import Foundation

/// Claude Code usage via the OAuth usage endpoint.
///
/// Credential priority: env `CLAUDE_CODE_OAUTH_TOKEN` → macOS Keychain
/// (through the `security` CLI, deliberately — see `keychainToken()`) →
/// `~/.claude/.credentials.json`.
actor ClaudeProvider: UsageProvider {
    nonisolated let id = "claude"
    nonisolated let displayName = "Claude Code"
    nonisolated let shortName = "Claude"
    nonisolated let glyph = ProviderGlyph.claude
    /// 120s, not 60: the usage endpoint has its own short-window rate limiter
    /// (429 with `retry-after: 0`, observed 2026-08-28) and other tools on the
    /// same machine may share it.
    nonisolated let pollInterval: TimeInterval = 120

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let authGuidance = "Re-authenticate in Claude Code"

    /// The ecosystem convention (llmquota, CodexBar) is to identify as the CLI;
    /// the default CFNetwork UA is the odd one out on this endpoint.
    private static let userAgent: String = {
        if let version = Usage.runCommand("/usr/bin/env", ["claude", "--version"], timeout: 5)?
            .split(separator: " ").first.map(String.init),
           version.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil {
            return "claude-cli/\(version) (external, cli)"
        }
        return "claude-cli/2.0.0 (external, cli)"
    }()

    /// Last successful snapshot, kept so a 429 (throttled, data not wrong)
    /// degrades to `.stale` instead of blanking the ring. Persisted so a
    /// relaunch during a hot throttle window still has numbers to show.
    private var lastGood: (snapshot: UsageSnapshot, at: Date)?
    private var restoredLastGood = false

    private static let lastGoodKey = "tachyon.lastGood.claude"

    private func restoreLastGoodIfNeeded() {
        guard !restoredLastGood else { return }
        restoredLastGood = true
        guard let data = UserDefaults.standard.data(forKey: Self.lastGoodKey),
              let stored = try? JSONDecoder().decode(StoredSnapshot.self, from: data)
        else { return }
        lastGood = (stored.snapshot, stored.at)
    }

    private func persistLastGood() {
        guard let last = lastGood,
              let data = try? JSONEncoder().encode(StoredSnapshot(snapshot: last.snapshot, at: last.at))
        else { return }
        UserDefaults.standard.set(data, forKey: Self.lastGoodKey)
    }

    private struct StoredSnapshot: Codable {
        let snapshot: UsageSnapshot
        let at: Date
    }

    /// Where a credential came from, so the 401 retry knows whether re-reading
    /// can possibly produce a different token.
    enum CredentialSource: Sendable {
        case environment
        case keychain
        case file
    }

    struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?
        let source: CredentialSource

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    /// Cached so we do not hit the keychain on every poll. Invalidated on 401
    /// or once `expiresAt` has passed — never unconditionally.
    private var cachedCredential: Credential?

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        if await credential() != nil { return .ready }
        if Usage.fileExists(Self.configDirectory) || Usage.fileExists(Self.credentialsPath) {
            return .notSignedIn("Run `claude` and sign in")
        }
        // No usable credential and no config dir. A second keychain probe here
        // would be dead code: `credential()` already walked env → keychain →
        // file, so a readable, parseable item would have returned `.ready`.
        return .notInstalled
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let initial = await credential() else {
            return .authError(Self.authGuidance)
        }
        do {
            var result = try await fetchUsage(token: initial.accessToken)
            var active = initial
            if result.status == 401 {
                // §2.1: re-read the *keychain* once, then give up for good.
                // An env-supplied token has no second source to consult — the
                // chain would hand back the same rejected bearer — so skip the
                // wasted round-trip and surface the auth error immediately.
                guard initial.source != .environment else {
                    return .authError(Self.authGuidance)
                }
                cachedCredential = nil
                guard let fresh = await credential(skipEnvironment: true),
                      fresh.accessToken != initial.accessToken
                else { return .authError(Self.authGuidance) }
                active = fresh
                result = try await fetchUsage(token: fresh.accessToken)
                if result.status == 401 { return .authError(Self.authGuidance) }
            }
            if result.status == 429 {
                // Throttled — our last reading is not wrong, just not fresh.
                // .notice so it lands in `log show` (info-level is not persisted).
                Log.provider.notice("claude usage throttled (429)")
                restoreLastGoodIfNeeded()
                if let last = lastGood { return .stale(last.snapshot, asOf: last.at) }
                return .unavailable
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("claude usage HTTP \(result.status)")
                return .unavailable
            }
            guard let snapshot = Self.decode(result.body, credential: active) else {
                Log.provider.error("claude usage decode produced no usable window")
                return .unavailable
            }
            lastGood = (snapshot, Date())
            persistLastGood()
            return .ok(snapshot)
        } catch {
            Log.provider.error("claude usage request failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    private func fetchUsage(token: String) async throws -> Usage.HTTPResult {
        try await Usage.get(Self.usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": Self.userAgent,
        ])
    }

    // MARK: - Decoding

    /// Optional-tolerant by construction: any missing field degrades the result
    /// rather than throwing. Returns nil only when no ring window can be built.
    static func decode(_ data: Data, credential: Credential? = nil) -> UsageSnapshot? {
        decode(JSONValue.parse(data), subscription: credential?.subscriptionType, tier: credential?.rateLimitTier)
    }

    static func decode(_ root: JSONValue, subscription: String?, tier: String?) -> UsageSnapshot? {
        let limits = root["limits"].array

        // Session window: five_hour, else limits[] kind == "session".
        let fiveHour = root["five_hour"]
        let sessionLimit = limits.first { $0["kind"].string == "session" }

        var windows: [UsageWindow] = []
        if let percent = fiveHour["utilization"].double {
            windows.append(UsageWindow(
                label: "Current session",
                percentUsed: percent,
                resetsAt: fiveHour["resets_at"].isoDate,
                windowSeconds: 5 * 3600
            ))
        } else if let sessionLimit, let percent = sessionLimit["percent"].double {
            windows.append(UsageWindow(
                label: "Current session",
                percentUsed: percent,
                resetsAt: sessionLimit["resets_at"].isoDate,
                windowSeconds: 5 * 3600
            ))
        }

        // limits[] rows, skipping the session entry (already captured above)
        // and anything the server marks inactive.
        var sawWeeklyAll = false
        for limit in limits {
            let kind = limit["kind"].string ?? ""
            guard kind != "session" else { continue }
            guard limit["is_active"].bool != false else { continue }
            guard let percent = limit["percent"].double else { continue }
            if kind == "weekly_all" { sawWeeklyAll = true }
            windows.append(UsageWindow(
                label: label(forKind: kind, scope: limit["scope"]),
                percentUsed: percent,
                resetsAt: limit["resets_at"].isoDate,
                windowSeconds: kind.contains("week") ? 7 * 86400 : nil
            ))
        }

        // seven_day only when limits[] did not already carry the all-models weekly.
        if !sawWeeklyAll, let percent = root["seven_day"]["utilization"].double {
            windows.append(UsageWindow(
                label: "Weekly",
                percentUsed: percent,
                resetsAt: root["seven_day"]["resets_at"].isoDate,
                windowSeconds: 7 * 86400
            ))
        }

        guard !windows.isEmpty else { return nil }

        // Worst-active-bounded-window rule: the ring is whichever hard limit
        // is closest to blocking — a weekly at 70% outranks a session at 10%.
        let ordered = windows.worstFirst()
        return UsageSnapshot(
            primary: ordered[0],
            windows: ordered,
            asOf: Date(),
            detail: planDetail(subscription: subscription, tier: tier)
        )
    }

    private static func label(forKind kind: String, scope: JSONValue) -> String {
        let base: String
        switch kind {
        case "weekly_all": base = "Weekly"
        case "weekly_scoped": base = "Weekly"
        case "opus_weekly": base = "Weekly (Opus)"
        default:
            base = kind
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
        if let model = scope["model"]["display_name"].string, !model.isEmpty {
            return "\(base) (\(model))"
        }
        if let surface = scope["surface"]["display_name"].string, !surface.isEmpty {
            return "\(base) (\(surface))"
        }
        return base
    }

    /// "max" + "default_claude_max_20x" → "Max (20x)". The raw tier string is
    /// an internal identifier, so only its distinguishing suffix is surfaced.
    private static func planDetail(subscription: String?, tier: String?) -> String? {
        let plan = subscription?.trimmingCharacters(in: .whitespaces)
        let base = (plan?.isEmpty ?? true) ? nil : plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }

        guard let tier = tier?.trimmingCharacters(in: .whitespaces), !tier.isEmpty else { return base }
        // Pull a multiplier like "20x" out of e.g. "default_claude_max_20x".
        let suffix = tier.split(separator: "_").last.map(String.init)
        if let base, let suffix, suffix.lowercased() != base.lowercased(),
           suffix.range(of: "^[0-9]+x$", options: [.regularExpression, .caseInsensitive]) != nil {
            return "\(base) (\(suffix))"
        }
        if let base { return base }
        return tier.prefix(1).uppercased() + tier.dropFirst()
    }

    // MARK: - Credential chain

    private static var configDirectory: String {
        Usage.env("CLAUDE_CONFIG_DIR") ?? Usage.homePath(".claude")
    }

    private static var credentialsPath: String {
        URL(fileURLWithPath: configDirectory).appendingPathComponent(".credentials.json").path
    }

    /// Walks the credential chain. `skipEnvironment` is used by the 401 retry:
    /// re-running the full chain would hand back the identical env token, so the
    /// retry would re-send a bearer the server just rejected (§2.1 specifies the
    /// retry as a *keychain* re-read).
    private func credential(skipEnvironment: Bool = false) async -> Credential? {
        if let cached = cachedCredential, !cached.isExpired { return cached }
        cachedCredential = nil

        // ① Environment override wins and carries no metadata.
        if !skipEnvironment, let token = Usage.env("CLAUDE_CODE_OAUTH_TOKEN") {
            let fromEnv = Credential(
                accessToken: token,
                expiresAt: nil,
                subscriptionType: nil,
                rateLimitTier: nil,
                source: .environment
            )
            cachedCredential = fromEnv
            return fromEnv
        }

        // ② Keychain, ③ credentials file.
        if let payload = Self.keychainToken(),
           let parsed = Self.parseCredential(payload, source: .keychain) {
            cachedCredential = parsed
            return parsed
        }
        guard let payload = Self.filePayload(),
              let parsed = Self.parseCredential(payload, source: .file)
        else { return nil }
        cachedCredential = parsed
        return parsed
    }

    /// Shelling out to `security` is deliberate: the "Always Allow" ACL binds to
    /// Apple's stably-signed binary and survives our ad-hoc rebuilds, whereas
    /// `SecItemCopyMatching` from this process re-prompts after every build.
    private static func keychainToken() -> String? {
        Usage.runCommand("/usr/bin/security", [
            "find-generic-password", "-s", keychainService, "-w",
        ])
    }

    private static func filePayload() -> String? {
        guard let data = FileManager.default.contents(atPath: credentialsPath) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseCredential(_ payload: String, source: CredentialSource) -> Credential? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let oauth = JSONValue.parse(data)["claudeAiOauth"]
        guard let token = oauth["accessToken"].string, !token.isEmpty else { return nil }
        // expiresAt is milliseconds since epoch.
        let expiresAt = oauth["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credential(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"].string,
            rateLimitTier: oauth["rateLimitTier"].string,
            source: source
        )
    }
}
