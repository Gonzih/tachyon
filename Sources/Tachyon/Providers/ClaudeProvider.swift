import CryptoKit
import Foundation

/// Claude Code usage via the OAuth usage endpoint.
///
/// Credential priority: env `CLAUDE_CODE_OAUTH_TOKEN` → macOS Keychain
/// (through the `security` CLI, deliberately) →
/// `~/.claude/.credentials.json`.
///
/// The credential/profile branches below are intentionally explicit: they
/// preserve Claude Code behavior across secure-storage modes, custom config
/// roots, legacy files, and machines with several installations. Complexity
/// refactors may extract this matrix, but must not collapse its priority or
/// fall through from a selected custom profile to an unrelated local account.
actor ClaudeProvider: UsageProvider {
    nonisolated let id = "claude"
    nonisolated let displayName = "Claude Code"
    nonisolated let shortName = "Claude"
    nonisolated let sourceLabel: String? = "Code"
    nonisolated let glyph = ProviderGlyph.claude
    /// 120s, not 60: the usage endpoint has its own short-window rate limiter
    /// (429 with `retry-after: 0`, observed 2026-08-28) and other tools on the
    /// same machine may share it.
    nonisolated let pollInterval: TimeInterval = 120
    /// Claude Code itself shares the usage endpoint's tight limiter. One
    /// missed scheduled refresh is routine, so retain all conservative stale
    /// behavior immediately but wait until the second missed poll (4 minutes)
    /// before putting the word "stale" in the UI.
    nonisolated let staleIndicatorDelay: TimeInterval = 240

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let baseKeychainService = "Claude Code-credentials"
    private static let authGuidance = "Re-authenticate in Claude Code"
    /// A 429 from the usage endpoint needs a longer quiet period than the
    /// normal poll cadence. This is provider-local so Refresh cannot punch
    /// through it and amplify a limiter shared with Claude Code itself.
    static let throttledRequestDelay: TimeInterval = 300
    /// Long enough that detect() and the immediately following snapshot() share
    /// one Keychain read; short enough that a login switch is seen by the next
    /// regular poll.
    static let credentialCacheTTL: TimeInterval = 60

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

    /// Last successful snapshot for the currently cached credential only. This
    /// deliberately stays in memory: a provider-wide persisted value can leak
    /// account A's numbers into account B after a login switch.
    private var lastGood: (snapshot: UsageSnapshot, at: Date, credentialToken: String)?

    /// Where a credential came from, so the 401 retry knows whether re-reading
    /// can possibly produce a different token.
    enum CredentialSource: Sendable, Equatable {
        case environment
        case keychain(service: String)
        case file(path: String)
    }

    struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?
        let source: CredentialSource

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }
    }

    struct Dependencies: Sendable {
        var environment: @Sendable (String) -> String?
        var homeDirectory: @Sendable () -> String
        var readKeychain: @Sendable (String) async -> String?
        var readFile: @Sendable (String) -> String?
        var fetchUsage: @Sendable (String) async throws -> Usage.HTTPResult
        var fetchProfile: @Sendable (String) async throws -> Usage.HTTPResult
        var now: @Sendable () -> Date
        /// Optional only so deterministic provider-unit fixtures do not sleep
        /// wall-clock minutes. Production always supplies the cancellable
        /// implementation below; pacing tests inject a controlled sleeper.
        var sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil

        static let live = Dependencies(
            environment: { ProcessInfo.processInfo.environment[$0] },
            homeDirectory: { NSHomeDirectory() },
            readKeychain: { service in
                await Task.detached(priority: .utility) {
                    Usage.runCommand("/usr/bin/security", [
                        "find-generic-password", "-s", service, "-w",
                    ])
                }.value
            },
            readFile: { path in
                guard let data = Usage.boundedFile(path: path, maximumBytes: 1024 * 1024) else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            },
            fetchUsage: { token in try await ClaudeProvider.fetch(ClaudeProvider.usageURL, token: token) },
            fetchProfile: { token in try await ClaudeProvider.fetch(ClaudeProvider.profileURL, token: token) },
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
    }

    private struct CachedCredential: Sendable {
        let credential: Credential
        let checkedAt: Date
    }

    private struct CachedAccountIdentity: Sendable {
        let token: String
        let fingerprint: String?
        let checkedAt: Date
    }

    private let dependencies: Dependencies
    private var cachedCredential: CachedCredential?
    private var activeCredentialToken: String?
    private var cachedAccountIdentity: CachedAccountIdentity?
    /// Deadline for the credential that most recently touched the endpoint.
    /// Kept in memory and token-scoped: switching accounts must not inherit the
    /// old account's limiter, and credentials are never persisted or logged.
    private var usageRequestGate: (credentialToken: String, notBefore: Date)?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        if await credential() != nil { return .ready }
        let locations = credentialLocations()
        if Usage.fileExists(locations.configDirectory) || Usage.fileExists(locations.filePath) {
            return .notSignedIn("Run `claude` and sign in")
        }
        // No usable credential and no config dir. A second keychain probe here
        // would be dead code: `credential()` already walked env → keychain →
        // file, so a readable, parseable item would have returned `.ready`.
        return .notInstalled
    }

    // MARK: - Snapshot

    private struct SnapshotAttempt: Sendable {
        let state: ProviderState
        /// The exact credential that produced `state`. Authentication failures
        /// intentionally carry nil so a rejected bearer is never sent again to
        /// the profile endpoint.
        let credential: Credential?
    }

    private enum UsageRequestOutcome: Sendable {
        case response(Usage.HTTPResult, credential: Credential)
        case finished(SnapshotAttempt)
    }

    /// Bind identity discovery to the exact credential used by the usage
    /// request. A slow request can cross the credential-cache TTL; reloading
    /// credentials afterward could otherwise pair account A's usage with
    /// account B's identity.
    func reading() async -> ProviderReading {
        let attempt = await snapshotAttempt()
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        let fingerprint: String? = if let credential = attempt.credential {
            await fingerprint(for: credential)
        } else {
            nil
        }
        return ProviderReading(state: attempt.state, accountFingerprint: fingerprint)
    }

    func snapshot() async -> ProviderState {
        await snapshotAttempt().state
    }

    private func snapshotAttempt() async -> SnapshotAttempt {
        guard let initial = await credential() else {
            return SnapshotAttempt(state: .authError(Self.authGuidance), credential: nil)
        }

        switch await requestUsage(for: initial) {
        case .finished(let attempt):
            return attempt
        case .response(let result, let credential):
            guard Self.isAuthenticationFailure(result.status) else {
                return snapshotAttempt(from: result, credential: credential)
            }
            return await retryAfterAuthenticationFailure(initial)
        }
    }

    private func requestUsage(for credential: Credential) async -> UsageRequestOutcome {
        guard await waitForUsageRequestPermit(for: credential) else {
            return .finished(cancelledAttempt())
        }
        // Another actor-reentrant read may have adopted a replacement while
        // this one waited. Never send the superseded account after that switch.
        guard activeCredentialToken == credential.accessToken else {
            return .finished(SnapshotAttempt(state: .unavailable, credential: nil))
        }
        do {
            let result = try await fetchUsage(token: credential.accessToken)
            recordUsageRequest(status: result.status, credential: credential)
            guard !Task.isCancelled else {
                return .finished(SnapshotAttempt(state: .unavailable, credential: nil))
            }
            return .response(result, credential: credential)
        } catch {
            recordUsageRequest(status: nil, credential: credential)
            guard !Task.isCancelled else {
                return .finished(SnapshotAttempt(state: .unavailable, credential: nil))
            }
            // Error descriptions can contain paths or transport details. Keep
            // production logs useful without making arbitrary strings public.
            Log.provider.error("claude usage request failed")
            return .finished(SnapshotAttempt(state: .unavailable, credential: credential))
        }
    }

    private func waitForUsageRequestPermit(for credential: Credential) async -> Bool {
        guard let gate = usageRequestGate,
              gate.credentialToken == credential.accessToken
        else { return !Task.isCancelled }
        let delay = gate.notBefore.timeIntervalSince(dependencies.now())
        guard delay.isFinite, delay > 0,
              let sleep = dependencies.sleep
        else { return !Task.isCancelled }
        do {
            try await sleep(delay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    private func recordUsageRequest(status: Int?, credential: Credential) {
        let delay = status == 429 ? Self.throttledRequestDelay : pollInterval
        usageRequestGate = (
            credentialToken: credential.accessToken,
            notBefore: dependencies.now().addingTimeInterval(delay)
        )
    }

    /// Re-read the exact location that supplied this token. Walking the full
    /// chain here could silently change accounts: a file token rejected by the
    /// server must not fall through to an unrelated Keychain login.
    private func retryAfterAuthenticationFailure(_ initial: Credential) async -> SnapshotAttempt {
        guard initial.source != .environment else {
            return rejectedAttempt(for: initial)
        }

        cachedCredential = nil
        guard let fresh = await loadCredential(from: initial.source) else {
            return Task.isCancelled ? cancelledAttempt() : rejectedAttempt(for: initial)
        }
        guard !Task.isCancelled else { return cancelledAttempt() }
        guard !fresh.isExpired(at: dependencies.now()),
              fresh.accessToken != initial.accessToken
        else { return rejectedAttempt(for: initial) }

        adopt(fresh, checkedAt: dependencies.now())
        switch await requestUsage(for: fresh) {
        case .finished(let attempt):
            return attempt
        case .response(let result, let credential):
            guard !Self.isAuthenticationFailure(result.status) else {
                return rejectedAttempt(for: credential)
            }
            return snapshotAttempt(from: result, credential: credential)
        }
    }

    private func snapshotAttempt(
        from result: Usage.HTTPResult,
        credential: Credential
    ) -> SnapshotAttempt {
        if result.status == 429 {
            // Throttled — our last reading is not wrong, just not fresh.
            // .notice so it lands in `log show` (info-level is not persisted).
            Log.provider.notice("claude usage throttled (429)")
            let state = staleState(for: credential)
            return SnapshotAttempt(state: state, credential: credential)
        }
        guard (200..<300).contains(result.status) else {
            Log.provider.error("claude usage HTTP \(result.status)")
            return SnapshotAttempt(state: .unavailable, credential: credential)
        }
        guard let snapshot = Self.decode(result.body, credential: credential) else {
            Log.provider.error("claude usage decode produced no usable window")
            return SnapshotAttempt(state: .unavailable, credential: credential)
        }
        if activeCredentialToken == credential.accessToken {
            lastGood = (snapshot, dependencies.now(), credential.accessToken)
        }
        return SnapshotAttempt(state: .ok(snapshot), credential: credential)
    }

    private func staleState(for credential: Credential) -> ProviderState {
        guard let lastGood, lastGood.credentialToken == credential.accessToken else {
            return .unavailable
        }
        return .stale(lastGood.snapshot, asOf: lastGood.at)
    }

    private func rejectedAttempt(for credential: Credential) -> SnapshotAttempt {
        SnapshotAttempt(state: authenticationError(for: credential), credential: nil)
    }

    private func cancelledAttempt() -> SnapshotAttempt {
        SnapshotAttempt(state: .unavailable, credential: nil)
    }

    private static func isAuthenticationFailure(_ status: Int) -> Bool {
        status == 401 || status == 403
    }

    private func fetchUsage(token: String) async throws -> Usage.HTTPResult {
        try await dependencies.fetchUsage(token)
    }

    /// UsageModel asks for identity after every poll, including failed auth.
    /// Remember this rejection so that call does not send the same rejected
    /// bearer to the profile endpoint immediately afterward.
    private func authenticationError(for credential: Credential) -> ProviderState {
        cachedAccountIdentity = CachedAccountIdentity(
            token: credential.accessToken,
            fingerprint: nil,
            checkedAt: dependencies.now()
        )
        return .authError(Self.authGuidance)
    }

    private static func fetch(_ url: URL, token: String) async throws -> Usage.HTTPResult {
        try await Usage.get(url, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": Self.userAgent,
        ])
    }

    /// Verified account + organization identity from Anthropic. The raw IDs
    /// exist only long enough to derive the per-launch opaque fingerprint.
    func accountFingerprint() async -> String? {
        guard let credential = await credential() else { return nil }
        return await fingerprint(for: credential)
    }

    private func fingerprint(for credential: Credential) async -> String? {
        let now = dependencies.now()
        if let cached = cachedAccountIdentity, cached.token == credential.accessToken {
            if let fingerprint = cached.fingerprint { return fingerprint }
            let age = now.timeIntervalSince(cached.checkedAt)
            if age >= 0, age < Self.credentialCacheTTL { return nil }
        }

        let fingerprint: String?
        do {
            let response = try await dependencies.fetchProfile(credential.accessToken)
            guard !Task.isCancelled else { return nil }
            guard (200..<300).contains(response.status),
                  let identity = Self.decodeProfileIdentity(response.body)
            else {
                cachedAccountIdentity = CachedAccountIdentity(
                    token: credential.accessToken,
                    fingerprint: nil,
                    checkedAt: now
                )
                return nil
            }
            fingerprint = OpaqueAccountIdentity.fingerprint(
                namespace: "claude",
                components: [identity.accountID, identity.organizationID]
            )
        } catch {
            guard !Task.isCancelled else { return nil }
            fingerprint = nil
        }
        cachedAccountIdentity = CachedAccountIdentity(
            token: credential.accessToken,
            fingerprint: fingerprint,
            checkedAt: now
        )
        return fingerprint
    }

    struct ProfileIdentity: Sendable, Equatable {
        let accountID: String
        let organizationID: String
    }

    static func decodeProfileIdentity(_ data: Data) -> ProfileIdentity? {
        let root = JSONValue.parse(data)
        guard let accountID = root["account"]["uuid"].string, !accountID.isEmpty,
              let organizationID = root["organization"]["uuid"].string, !organizationID.isEmpty
        else { return nil }
        return ProfileIdentity(accountID: accountID, organizationID: organizationID)
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

    struct CredentialLocations: Sendable, Equatable {
        let configDirectory: String
        let keychainService: String
        let filePath: String
    }

    private func credentialLocations() -> CredentialLocations {
        Self.credentialLocations(
            claudeConfigDirectory: dependencies.environment("CLAUDE_CONFIG_DIR"),
            secureStorageDirectory: dependencies.environment("CLAUDE_SECURESTORAGE_CONFIG_DIR"),
            homeDirectory: dependencies.homeDirectory()
        )
    }

    /// Claude Code hashes the exact secure-storage override string, without
    /// path normalization. An explicitly empty secure-storage override pins
    /// the legacy unsuffixed service.
    static func credentialLocations(
        claudeConfigDirectory: String?,
        secureStorageDirectory: String?,
        homeDirectory: String
    ) -> CredentialLocations {
        let configDirectory = nonEmpty(claudeConfigDirectory)
            ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude").path
        let secureDirectory = secureStorageDirectory ?? claudeConfigDirectory
        let service: String
        if let secureDirectory, !secureDirectory.isEmpty {
            let normalized = secureDirectory.precomposedStringWithCanonicalMapping
            let digest = SHA256.hash(data: Data(normalized.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            service = "\(baseKeychainService)-\(suffix)"
        } else {
            service = baseKeychainService
        }
        return CredentialLocations(
            configDirectory: configDirectory,
            keychainService: service,
            filePath: URL(fileURLWithPath: configDirectory)
                .appendingPathComponent(".credentials.json").path
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Walk the configured priority chain. The bounded cache prevents duplicate
    /// Keychain reads during one poll while still noticing account switches.
    private func credential() async -> Credential? {
        let now = dependencies.now()
        if let cached = cachedCredential {
            let age = now.timeIntervalSince(cached.checkedAt)
            if age >= 0, age < Self.credentialCacheTTL,
               !cached.credential.isExpired(at: now) {
                return cached.credential
            }
        }
        cachedCredential = nil

        // ① Environment override wins and carries no metadata.
        if let token = Self.trimmed(dependencies.environment("CLAUDE_CODE_OAUTH_TOKEN")) {
            let fromEnv = Credential(
                accessToken: token,
                expiresAt: nil,
                subscriptionType: nil,
                rateLimitTier: nil,
                source: .environment
            )
            adopt(fromEnv, checkedAt: now)
            return fromEnv
        }

        // ② Keychain, ③ credentials file.
        let locations = credentialLocations()
        let keychain = CredentialSource.keychain(service: locations.keychainService)
        if let parsed = await loadCredential(from: keychain) {
            guard !Task.isCancelled else { return nil }
            let checkedAt = dependencies.now()
            if !parsed.isExpired(at: checkedAt) {
                adopt(parsed, checkedAt: checkedAt)
                return parsed
            }
        } else if Task.isCancelled {
            return nil
        }
        let file = CredentialSource.file(path: locations.filePath)
        guard let parsed = await loadCredential(from: file) else {
            guard !Task.isCancelled else { return nil }
            clearCredentialState()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let checkedAt = dependencies.now()
        guard !parsed.isExpired(at: checkedAt) else {
            clearCredentialState()
            return nil
        }
        adopt(parsed, checkedAt: checkedAt)
        return parsed
    }

    private func adopt(_ credential: Credential, checkedAt: Date) {
        if activeCredentialToken != credential.accessToken {
            // A rotated token may belong to the same account, but discarding
            // stale data is safer than carrying it across a possible switch.
            lastGood = nil
            cachedAccountIdentity = nil
        }
        activeCredentialToken = credential.accessToken
        cachedCredential = CachedCredential(credential: credential, checkedAt: checkedAt)
    }

    private func clearCredentialState() {
        cachedCredential = nil
        activeCredentialToken = nil
        cachedAccountIdentity = nil
        lastGood = nil
    }

    /// Re-read one exact source. This function never falls through to another
    /// location, which is essential on machines with different accounts in the
    /// CLI config, Keychain, and Desktop app.
    private func loadCredential(from source: CredentialSource) async -> Credential? {
        let payload: String?
        switch source {
        case .environment:
            guard let token = Self.trimmed(dependencies.environment("CLAUDE_CODE_OAUTH_TOKEN"))
            else { return nil }
            return Credential(
                accessToken: token,
                expiresAt: nil,
                subscriptionType: nil,
                rateLimitTier: nil,
                source: .environment
            )
        case .keychain(let service):
            payload = await dependencies.readKeychain(service)
        case .file(let path):
            payload = dependencies.readFile(path)
        }
        guard let payload else { return nil }
        return Self.parseCredential(payload, source: source)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func parseCredential(_ payload: String, source: CredentialSource) -> Credential? {
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
