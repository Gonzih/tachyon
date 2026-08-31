import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

/// Claude subscription usage from the signed-in Claude Desktop application.
///
/// This is intentionally a read-only integration. It opens Electron's cookie
/// database read-only, decrypts cookies in memory with Claude Safe Storage,
/// and sends them only to `https://claude.ai`. Nothing is copied into Tachyon's
/// Keychain or defaults, and raw account identifiers never leave this actor.
///
/// Keep discovery and retry branches explicit. They are a compatibility matrix
/// for Electron cookie layouts and macOS install locations, not accidental
/// duplication; simplify by extraction only, never by dropping a candidate.
actor ClaudeDesktopProvider: UsageProvider {
    nonisolated let id = "claude-desktop"
    nonisolated let displayName = "Claude Desktop"
    nonisolated let shortName = "Claude"
    nonisolated let sourceLabel: String? = "Desktop"
    nonisolated let glyph = ProviderGlyph.claude
    nonisolated let pollInterval: TimeInterval = 120
    /// The claude.ai usage endpoint is shared with the signed-in app and can
    /// transiently throttle Tachyon. Match Claude Code's one-missed-poll UI
    /// grace without treating the cached reading as fresh internally.
    nonisolated let staleIndicatorDelay: TimeInterval = 240
    nonisolated var watchPaths: [String] { monitoredSupportPaths }

    private static let baseURL = URL(string: "https://claude.ai")!
    private static let safeStorageService = "Claude Safe Storage"
    private static let cacheTTL: TimeInterval = 60
    private static let authGuidance = "Sign in again in Claude Desktop"
    private static let defaultSupportDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    private static let fallbackUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/131.0.0.0 Safari/537.36"

    enum ReadError: Error, Sendable {
        case database
        case keychain
    }

    struct Cookie: Sendable, Equatable {
        let host: String
        let path: String
        let name: String
        let value: String
        let expiresAt: Date?
        let isSecure: Bool

        func applies(to url: URL, now: Date) -> Bool {
            guard let requestHost = url.host?.lowercased(),
                  Self.domain(host, matches: requestHost),
                  Self.path(path, matches: url.path.isEmpty ? "/" : url.path),
                  !isSecure || url.scheme?.lowercased() == "https",
                  expiresAt.map({ $0 > now }) ?? true
            else { return false }
            return true
        }

        private static func domain(_ cookieHost: String, matches requestHost: String) -> Bool {
            let normalized = cookieHost.lowercased()
            if normalized.hasPrefix(".") {
                let suffix = String(normalized.dropFirst())
                return requestHost == suffix || requestHost.hasSuffix("." + suffix)
            }
            return requestHost == normalized
        }

        private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
            let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
            guard requestPath.hasPrefix(cookiePath) else { return false }
            if requestPath.count == cookiePath.count || cookiePath.hasSuffix("/") { return true }
            let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            return requestPath[boundary] == "/"
        }
    }

    struct CookieJar: Sendable, Equatable {
        let cookies: [Cookie]

        func value(named name: String, for url: URL, now: Date) -> String? {
            acceptedCookies(for: url, now: now)
                .first(where: { $0.name == name && !$0.value.isEmpty })?
                .value
        }

        func unambiguousValue(named name: String, for url: URL, now: Date) -> String? {
            let values = acceptedCookies(for: url, now: now)
                .filter { $0.name == name && !$0.value.isEmpty }
                .map(\.value)
            guard let first = values.first,
                  values.dropFirst().allSatisfy({ $0 == first }) else { return nil }
            return first
        }

        func hasConflictingValues(named name: String, for url: URL, now: Date) -> Bool {
            var first: String?
            for cookie in acceptedCookies(for: url, now: now)
            where cookie.name == name && !cookie.value.isEmpty {
                if let first, first != cookie.value { return true }
                first = cookie.value
            }
            return false
        }

        func header(for url: URL, now: Date) -> String? {
            let accepted = acceptedCookies(for: url, now: now)
            guard !accepted.isEmpty else { return nil }
            return accepted.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        /// The identity cache and the actual request must select from exactly
        /// the same cookie set. This excludes expired/path-mismatched duplicate
        /// session rows and cookies rejected by the header safety/size bounds.
        private func acceptedCookies(for url: URL, now: Date) -> [Cookie] {
            let applicable = cookies
                .filter { $0.applies(to: url, now: now) }
                .sorted {
                    let lhsIsIdentity = $0.name == "sessionKey" || $0.name == "lastActiveOrg"
                    let rhsIsIdentity = $1.name == "sessionKey" || $1.name == "lastActiveOrg"
                    if lhsIsIdentity != rhsIsIdentity { return lhsIsIdentity }
                    if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                    return $0.name < $1.name
                }

            var accepted: [Cookie] = []
            var byteCount = 0
            for cookie in applicable {
                guard accepted.count < 128 else { break }
                guard Self.isSafeCookieName(cookie.name), Self.isSafeCookieValue(cookie.value)
                else { continue }
                let nextByteCount = byteCount
                    + cookie.name.utf8.count + 1 + cookie.value.utf8.count
                    + (accepted.isEmpty ? 0 : 2)
                // One oversized, unrelated cookie must not shadow a later
                // applicable session key. Skip it and continue filling the
                // bounded header with usable fields.
                guard nextByteCount <= 32 * 1024 else { continue }
                accepted.append(cookie)
                byteCount = nextByteCount
            }
            return accepted
        }

        private static func isSafeCookieName(_ name: String) -> Bool {
            guard !name.isEmpty else { return false }
            return name.utf8.allSatisfy { byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                     0x21, 0x23...0x27, 0x2A...0x2B, 0x2D...0x2E,
                     0x5E...0x60, 0x7C, 0x7E:
                    true
                default:
                    false
                }
            }
        }

        private static func isSafeCookieValue(_ value: String) -> Bool {
            // RFC 6265 cookie-octet: visible ASCII excluding DQUOTE, comma,
            // semicolon, and backslash. This also rejects controls and Unicode.
            value.utf8.allSatisfy { byte in
                switch byte {
                case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E:
                    true
                default:
                    false
                }
            }
        }
    }

    struct SessionMaterial: Sendable, Equatable {
        let cookies: CookieJar
        let userAgent: String

        func selectionKey(now: Date) -> SelectionKey? {
            guard !cookies.hasConflictingValues(
                named: "sessionKey",
                for: ClaudeDesktopProvider.apiScopeURL,
                now: now
            ), !cookies.hasConflictingValues(
                named: "sessionKey",
                for: ClaudeDesktopProvider.bootstrapURL,
                now: now
            ), !cookies.hasConflictingValues(
                named: "lastActiveOrg",
                for: ClaudeDesktopProvider.bootstrapURL,
                now: now
            ), let sessionKey = cookies.unambiguousValue(
                named: "sessionKey",
                for: ClaudeDesktopProvider.apiScopeURL,
                now: now
            ), cookies.unambiguousValue(
                named: "sessionKey",
                for: ClaudeDesktopProvider.bootstrapURL,
                now: now
            ) == sessionKey else { return nil }
            return SelectionKey(
                sessionKey: sessionKey,
                organizationHint: cookies.unambiguousValue(
                    named: "lastActiveOrg",
                    for: ClaudeDesktopProvider.bootstrapURL,
                    now: now
                )
            )
        }
    }

    struct SelectionKey: Sendable, Equatable {
        let sessionKey: String
        let organizationHint: String?
    }

    struct DesktopLocations: Sendable, Equatable {
        let applicationURL: URL?
        let supportDirectories: [URL]
    }

    /// Compatibility matrix, not incidental verbosity: Claude supports both
    /// system- and user-installed bundles, and current Desktop builds can move
    /// Chromium's user-data root with `CLAUDE_USER_DATA_DIR`. Keep every known
    /// candidate here when extracting helpers for complexity; a machine-local
    /// happy path is not an acceptable substitute for cross-version discovery.
    static func desktopLocations(
        homeDirectory: String,
        claudeUserDataDirectory: String?,
        resolveApplication: () -> URL?,
        fileExists: (String) -> Bool
    ) -> DesktopLocations {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let knownApplications = [
            URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true),
            home.appendingPathComponent("Applications/Claude.app", isDirectory: true),
        ]
        let applicationURL = uniqueStandardizedURLs(
            [resolveApplication()].compactMap { $0 } + knownApplications
        ).first { fileExists($0.path) }

        let defaultSupport = home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        var supportCandidates: [URL] = []
        if let override = absoluteDirectory(claudeUserDataDirectory) {
            supportCandidates.append(override)
        }
        supportCandidates.append(defaultSupport)
        return DesktopLocations(
            applicationURL: applicationURL,
            supportDirectories: uniqueStandardizedURLs(supportCandidates)
        )
    }

    private static func resolveApplication() -> URL? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.anthropic.claudefordesktop"
            )
    }

    private static func absoluteDirectory(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return paths.insert(standardized.path).inserted ? standardized : nil
        }
    }

    struct Dependencies: Sendable {
        let supportDirectories: [URL]
        var isInstalled: @Sendable () -> Bool
        var loadSession: @Sendable (SessionMaterial?) async throws -> SessionMaterial?
        var fetch: @Sendable (URL, [String: String]) async throws -> Usage.HTTPResult
        var now: @Sendable () -> Date

        init(
            supportDirectories: [URL] = [ClaudeDesktopProvider.defaultSupportDirectory],
            isInstalled: @escaping @Sendable () -> Bool,
            loadSession: @escaping @Sendable (SessionMaterial?) async throws -> SessionMaterial?,
            fetch: @escaping @Sendable (URL, [String: String]) async throws -> Usage.HTTPResult,
            now: @escaping @Sendable () -> Date
        ) {
            self.supportDirectories = supportDirectories
            self.isInstalled = isInstalled
            self.loadSession = loadSession
            self.fetch = fetch
            self.now = now
        }

        static var live: Dependencies {
            let fileExists: @Sendable (String) -> Bool = {
                FileManager.default.fileExists(atPath: $0)
            }
            let locations = ClaudeDesktopProvider.desktopLocations(
                homeDirectory: NSHomeDirectory(),
                claudeUserDataDirectory: ProcessInfo.processInfo.environment["CLAUDE_USER_DATA_DIR"],
                resolveApplication: ClaudeDesktopProvider.resolveApplication,
                fileExists: fileExists
            )
            let cookiePaths = locations.supportDirectories.flatMap { support in
                [
                    support.appendingPathComponent("Network/Cookies").path,
                    support.appendingPathComponent("Cookies").path,
                ]
            }
            let appPath = locations.applicationURL?.path ?? "/Applications/Claude.app"
            return Dependencies(
                supportDirectories: locations.supportDirectories,
                isInstalled: {
                    locations.applicationURL != nil
                        || locations.supportDirectories.contains { fileExists($0.path) }
                },
                loadSession: { excludedMaterial in
                    try await Task.detached(priority: .utility) {
                        try ClaudeDesktopProvider.firstUsableSession(
                            cookiePaths: cookiePaths,
                            now: Date(),
                            userAgent: ClaudeDesktopProvider.cachedUserAgent(appPath: appPath),
                            excluding: excludedMaterial,
                            fileExists: fileExists,
                            loadCookieJar: ClaudeDesktopProvider.loadCookieJar(at:)
                        )
                    }.value
                },
                fetch: { url, headers in try await Usage.get(url, headers: headers) },
                now: Date.init
            )
        }
    }

    struct BootstrapIdentity: Sendable, Equatable {
        let accountID: String
        let organizationID: String
        let subscription: String?
    }

    private struct VerifiedContext: Sendable {
        let organizationID: String
        let subscription: String?
        let fingerprint: String?
    }

    private struct CachedSession: Sendable {
        let material: SessionMaterial
        let checkedAt: Date
    }

    private struct SuccessfulPoll: Sendable {
        let snapshot: UsageSnapshot
        let fingerprint: String?
        let selection: SelectionKey
    }

    private struct RejectedSelection: Sendable {
        let selection: SelectionKey
        let checkedAt: Date
    }

    private enum PollFailure: Error {
        case authentication
        case throttled(fingerprint: String?)
        case unavailable(fingerprint: String?)
    }

    private enum SessionOutcome: Sendable {
        case available(SessionMaterial)
        case authentication
        case unavailable
    }

    private enum PollOutcome: Sendable {
        case success(SuccessfulPoll)
        case authentication
        case finished(ProviderReading)
    }

    private let dependencies: Dependencies
    private nonisolated let monitoredSupportPaths: [String]
    private var cachedSession: CachedSession?
    private var activeSelection: SelectionKey?
    private var cachedContext: (selection: SelectionKey, context: VerifiedContext)?
    private var rejectedSelection: RejectedSelection?
    private var lastGood: (snapshot: UsageSnapshot, at: Date, selection: SelectionKey)?
    /// Exposed only for focused diagnostics/tests. Scheduler reads use the
    /// fingerprint returned directly by `performReading()` rather than this
    /// shared completion cache.
    private var lastCompletedFingerprint: String?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        self.monitoredSupportPaths = dependencies.supportDirectories.map {
            $0.standardizedFileURL.path
        }
    }

    func detect() async -> ProviderPresence {
        do {
            if try await session() != nil { return .ready }
        } catch {
            // Installed-but-unreadable is actionable in the same place as a
            // signed-out Desktop session; never expose database/keychain text.
        }
        return dependencies.isInstalled()
            ? .notSignedIn("Open Claude Desktop and sign in")
            : .notInstalled
    }

    func snapshot() async -> ProviderState {
        let reading = await performReading()
        guard !Task.isCancelled else { return .unavailable }
        lastCompletedFingerprint = reading.accountFingerprint
        return reading.state
    }

    func reading() async -> ProviderReading {
        let reading = await performReading()
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        lastCompletedFingerprint = reading.accountFingerprint
        return reading
    }

    func accountFingerprint() async -> String? {
        lastCompletedFingerprint
    }

    private func performReading() async -> ProviderReading {
        switch await initialSession() {
        case .available(let material):
            return await performReading(using: material)
        case .authentication:
            return authenticationReading()
        case .unavailable:
            return unavailableReading()
        }
    }

    private func initialSession() async -> SessionOutcome {
        do {
            guard let material = try await session(),
                  material.selectionKey(now: dependencies.now()) != nil
            else { return .authentication }
            return .available(material)
        } catch {
            return .unavailable
        }
    }

    private func performReading(using material: SessionMaterial) async -> ProviderReading {
        switch await pollOutcome(for: material) {
        case .success(let success):
            return accept(success)
        case .authentication:
            return await retryAfterAuthenticationFailure(material)
        case .finished(let reading):
            return reading
        }
    }

    private func retryAfterAuthenticationFailure(
        _ rejectedMaterial: SessionMaterial
    ) async -> ProviderReading {
        guard !Task.isCancelled else { return unavailableReading() }
        switch await replacementSession(for: rejectedMaterial) {
        case .available(let fresh):
            return await performRetry(using: fresh)
        case .authentication:
            reject(rejectedMaterial)
            return authenticationReading()
        case .unavailable:
            return unavailableReading()
        }
    }

    private func replacementSession(for material: SessionMaterial) async -> SessionOutcome {
        do {
            guard let fresh = try await session(force: true, excluding: material), fresh != material else {
                return Task.isCancelled ? .unavailable : .authentication
            }
            return .available(fresh)
        } catch {
            // A database lock or denied Safe Storage read is not evidence that
            // the user's Claude session was rejected. Never poison the auth
            // rejection cache with a machine-local I/O failure.
            return .unavailable
        }
    }

    private func performRetry(using material: SessionMaterial) async -> ProviderReading {
        switch await pollOutcome(for: material) {
        case .success(let success):
            return accept(success)
        case .authentication:
            guard !Task.isCancelled else { return unavailableReading() }
            reject(material)
            return authenticationReading()
        case .finished(let reading):
            return reading
        }
    }

    private func pollOutcome(for material: SessionMaterial) async -> PollOutcome {
        do {
            return .success(try await poll(material))
        } catch PollFailure.authentication {
            return .authentication
        } catch PollFailure.throttled(let fingerprint) {
            Log.provider.notice("claude desktop usage throttled (429)")
            return .finished(throttledReading(for: material, fingerprint: fingerprint))
        } catch PollFailure.unavailable(let fingerprint) {
            Log.provider.error("claude desktop usage request failed")
            return .finished(unavailableReading(fingerprint: fingerprint))
        } catch {
            Log.provider.error("claude desktop usage request failed")
            return .finished(unavailableReading())
        }
    }

    private func accept(_ success: SuccessfulPoll) -> ProviderReading {
        guard !Task.isCancelled else { return unavailableReading() }
        rejectedSelection = nil
        if activeSelection == success.selection {
            lastGood = (
                success.snapshot,
                dependencies.now(),
                success.selection
            )
        }
        return ProviderReading(
            state: .ok(success.snapshot),
            accountFingerprint: success.fingerprint
        )
    }

    private func throttledReading(
        for material: SessionMaterial,
        fingerprint: String?
    ) -> ProviderReading {
        let selection = material.selectionKey(now: dependencies.now())
        guard let selection, let lastGood, lastGood.selection == selection else {
            return unavailableReading(fingerprint: fingerprint)
        }
        return ProviderReading(
            state: .stale(lastGood.snapshot, asOf: lastGood.at),
            accountFingerprint: fingerprint
        )
    }

    private func authenticationReading() -> ProviderReading {
        ProviderReading(state: .authError(Self.authGuidance), accountFingerprint: nil)
    }

    private func unavailableReading(fingerprint: String? = nil) -> ProviderReading {
        ProviderReading(state: .unavailable, accountFingerprint: fingerprint)
    }

    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool {
        return changedPaths.contains { changedPath in
            let url = URL(fileURLWithPath: changedPath).standardizedFileURL
            let path = url.path
            guard let supportPath = monitoredSupportPaths.first(where: {
                path == $0 || path.hasPrefix($0 + "/")
            }) else { return false }
            if path == supportPath { return true }
            switch url.lastPathComponent {
            case "Cookies", "Cookies-wal", "Cookies-shm", "Cookies-journal":
                return true
            default:
                return false
            }
        }
    }

    func fileChanged(_ path: String) async {
        guard shouldRefresh(changedPaths: [path]) else { return }
        // Preserve the current last-good reading until the exact replacement
        // session is known. `session()` clears it if the account/org changed.
        cachedSession = nil
    }

    private func poll(_ material: SessionMaterial) async throws -> SuccessfulPoll {
        guard let selection = material.selectionKey(now: dependencies.now()) else {
            throw PollFailure.authentication
        }
        let context = try await verifiedContext(for: material)
        guard !Task.isCancelled else {
            throw PollFailure.unavailable(fingerprint: nil)
        }
        let usageURL = Self.usageURL(organizationID: context.organizationID)
        guard !material.cookies.hasConflictingValues(
            named: "sessionKey",
            for: usageURL,
            now: dependencies.now()
        ), material.cookies.unambiguousValue(
            named: "sessionKey",
            for: usageURL,
            now: dependencies.now()
        ) == selection.sessionKey else { throw PollFailure.authentication }
        let result: Usage.HTTPResult
        do {
            result = try await request(usageURL, using: material)
        } catch {
            throw PollFailure.unavailable(fingerprint: context.fingerprint)
        }
        guard !Task.isCancelled else {
            throw PollFailure.unavailable(fingerprint: nil)
        }
        switch result.status {
        case 200..<300:
            guard let snapshot = ClaudeProvider.decode(
                JSONValue.parse(result.body),
                subscription: context.subscription,
                tier: nil
            ) else {
                throw PollFailure.unavailable(fingerprint: context.fingerprint)
            }
            return SuccessfulPoll(
                snapshot: snapshot,
                fingerprint: context.fingerprint,
                selection: selection
            )
        case 401, 403:
            throw PollFailure.authentication
        case 429:
            throw PollFailure.throttled(fingerprint: context.fingerprint)
        default:
            throw PollFailure.unavailable(fingerprint: context.fingerprint)
        }
    }

    private func verifiedContext(for material: SessionMaterial) async throws -> VerifiedContext {
        guard let selection = material.selectionKey(now: dependencies.now())
        else { throw PollFailure.authentication }
        if let cachedContext, cachedContext.selection == selection { return cachedContext.context }

        let response = try await request(Self.bootstrapURL, using: material)
        guard !Task.isCancelled else {
            throw PollFailure.unavailable(fingerprint: nil)
        }
        switch response.status {
        case 200..<300:
            guard let identity = Self.decodeBootstrap(
                response.body,
                activeOrganization: selection.organizationHint
            ) else { throw PollFailure.unavailable(fingerprint: nil) }
            let context = VerifiedContext(
                organizationID: identity.organizationID,
                subscription: identity.subscription,
                fingerprint: OpaqueAccountIdentity.fingerprint(
                    namespace: "claude",
                    components: [identity.accountID, identity.organizationID]
                )
            )
            cachedContext = (selection, context)
            return context
        case 401, 403:
            throw PollFailure.authentication
        case 429:
            throw PollFailure.throttled(fingerprint: nil)
        default:
            throw PollFailure.unavailable(fingerprint: nil)
        }
    }

    private func request(_ url: URL, using material: SessionMaterial) async throws -> Usage.HTTPResult {
        guard url.scheme == "https", url.host == "claude.ai",
              let cookieHeader = material.cookies.header(for: url, now: dependencies.now())
        else { throw PollFailure.unavailable(fingerprint: nil) }
        return try await dependencies.fetch(url, [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Cookie": cookieHeader,
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai/",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
            "User-Agent": material.userAgent,
        ])
    }

    /// The branches below are a cross-version/cross-machine compatibility
    /// matrix. Complexity refactors may extract them, but must not drop cookie
    /// candidates or collapse local I/O failures into authentication failures.
    private func session(
        force: Bool = false,
        excluding excludedMaterial: SessionMaterial? = nil
    ) async throws -> SessionMaterial? {
        let now = dependencies.now()
        if !force, let cachedSession {
            let age = now.timeIntervalSince(cachedSession.checkedAt)
            if age >= 0, age < Self.cacheTTL,
               let selection = cachedSession.material.selectionKey(now: now) {
                return isRecentlyRejected(selection, now: now)
                    ? nil
                    : cachedSession.material
            }
        }

        cachedSession = nil
        let loaded = try await dependencies.loadSession(excludedMaterial)
        guard !Task.isCancelled else { return nil }
        let completedAt = dependencies.now()
        guard let material = loaded,
              let selection = material.selectionKey(now: completedAt) else {
            clearSessionState()
            return nil
        }
        if activeSelection != selection {
            cachedContext = nil
            rejectedSelection = nil
            lastGood = nil
        }
        activeSelection = selection
        cachedSession = CachedSession(material: material, checkedAt: completedAt)
        if !force, isRecentlyRejected(selection, now: completedAt) { return nil }
        return material
    }

    private func reject(_ material: SessionMaterial) {
        let now = dependencies.now()
        rejectedSelection = material.selectionKey(now: now).map {
            RejectedSelection(selection: $0, checkedAt: now)
        }
        cachedContext = nil
    }

    private func isRecentlyRejected(_ selection: SelectionKey, now: Date) -> Bool {
        guard let rejectedSelection,
              rejectedSelection.selection == selection else { return false }
        let age = now.timeIntervalSince(rejectedSelection.checkedAt)
        guard age >= 0, age < Self.cacheTTL else {
            self.rejectedSelection = nil
            return false
        }
        return true
    }

    private func clearSessionState() {
        cachedSession = nil
        activeSelection = nil
        cachedContext = nil
        rejectedSelection = nil
        lastGood = nil
    }

    private static let bootstrapURL = baseURL
        .appendingPathComponent("api")
        .appendingPathComponent("bootstrap")

    /// A session cookie has to cover both bootstrap and organization usage,
    /// not merely one path-specific request.
    private static let apiScopeURL = baseURL
        .appendingPathComponent("api", isDirectory: true)

    static func usageURL(organizationID: String) -> URL {
        baseURL.appendingPathComponent("api")
            .appendingPathComponent("organizations")
            .appendingPathComponent(organizationID)
            .appendingPathComponent("usage")
    }

    // MARK: - Bootstrap identity

    static func decodeBootstrap(_ data: Data, activeOrganization: String?) -> BootstrapIdentity? {
        let account = JSONValue.parse(data)["account"]
        guard let accountID = nonEmpty(account["uuid"].string) else { return nil }

        let organizations: [(id: String, capabilities: [String])] = account["memberships"].array
            .compactMap { membership in
                let organization = membership["organization"]
                guard let id = nonEmpty(organization["uuid"].string) else { return nil }
                let capabilities = organization["capabilities"].array.compactMap(\.string)
                return (id, capabilities)
            }
            .filter { $0.capabilities.contains("chat") }
        guard !organizations.isEmpty else { return nil }

        let selected: (id: String, capabilities: [String])
        if let activeOrganization = nonEmpty(activeOrganization) {
            guard let match = organizations.first(where: { $0.id == activeOrganization })
            else { return nil }
            selected = match
        } else {
            selected = organizations[0]
        }

        let subscription: String?
        if selected.capabilities.contains("claude_max") { subscription = "max" }
        else if selected.capabilities.contains("claude_pro") { subscription = "pro" }
        else if selected.capabilities.contains("team") { subscription = "team" }
        else { subscription = nil }
        return BootstrapIdentity(
            accountID: accountID,
            organizationID: selected.id,
            subscription: subscription
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Chromium cookie store

    /// Chromium has used both `Cookies` and `Network/Cookies`. This loop is a
    /// compatibility matrix: multiple files can coexist after upgrades, and a
    /// structurally valid but server-rejected old database must not mask a
    /// later candidate. Keep every path and the exact-material exclusion when
    /// reducing complexity; never merge cookie rows across databases.
    static func firstUsableSession(
        cookiePaths: [String],
        now: Date,
        userAgent: String,
        excluding excludedMaterial: SessionMaterial? = nil,
        fileExists: (String) -> Bool,
        loadCookieJar: (String) throws -> CookieJar?
    ) throws -> SessionMaterial? {
        var firstFailure: Error?
        for path in cookiePaths where fileExists(path) {
            do {
                guard let jar = try loadCookieJar(path) else { continue }
                let material = SessionMaterial(cookies: jar, userAgent: userAgent)
                guard material.selectionKey(now: now) != nil,
                      material != excludedMaterial else { continue }
                return material
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        return nil
    }

    private struct StoredCookie {
        let host: String
        let path: String
        let name: String
        let plainValue: String
        let encryptedValue: Data
        let expiresAt: Date?
        let isSecure: Bool
    }

    private struct CookieDecodeState {
        var key: Data?
        var attemptedKeyLoad = false
        var encryptedSessionWithoutKey = false
    }

    static func loadCookieJar(at path: String) throws -> CookieJar? {
        try loadCookieJar(at: path, loadCookieKey: cookieDecryptionKey)
    }

    /// Plaintext cookies exist in older/test Chromium stores. An unrelated
    /// encrypted row must not make a valid plaintext session depend on Safe
    /// Storage, while an encrypted-only identity still reports an I/O failure
    /// rather than pretending the user signed out.
    static func loadCookieJar(
        at path: String,
        loadCookieKey: () -> Data?
    ) throws -> CookieJar? {
        let (schemaVersion, rows) = try readCookieRows(at: path)
        guard !rows.isEmpty else { return nil }

        var cookies: [Cookie] = []
        cookies.reserveCapacity(rows.count)
        var decodeState = CookieDecodeState()
        for row in rows {
            guard let value = cookieValue(
                for: row,
                schemaVersion: schemaVersion,
                state: &decodeState,
                loadCookieKey: loadCookieKey
            ), !value.isEmpty else { continue }
            cookies.append(Cookie(
                host: row.host,
                path: row.path,
                name: row.name,
                value: value,
                expiresAt: row.expiresAt,
                isSecure: row.isSecure
            ))
        }
        let hasPlainOrDecryptedSession = cookies.contains {
            $0.name == "sessionKey" && !$0.value.isEmpty
        }
        if decodeState.encryptedSessionWithoutKey, !hasPlainOrDecryptedSession {
            throw ReadError.keychain
        }
        return cookies.isEmpty ? nil : CookieJar(cookies: cookies)
    }

    private static func cookieValue(
        for row: StoredCookie,
        schemaVersion: Int,
        state: inout CookieDecodeState,
        loadCookieKey: () -> Data?
    ) -> String? {
        if !row.plainValue.isEmpty { return row.plainValue }
        guard !row.encryptedValue.isEmpty else { return nil }
        if !state.attemptedKeyLoad {
            state.key = loadCookieKey()
            state.attemptedKeyLoad = true
        }
        guard let key = state.key else {
            if row.name == "sessionKey" { state.encryptedSessionWithoutKey = true }
            return nil
        }
        return decryptCookie(
            row.encryptedValue,
            host: row.host,
            schemaVersion: schemaVersion,
            key: key
        )
    }

    private static func readCookieRows(at path: String) throws -> (Int, [StoredCookie]) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw ReadError.database
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_db_readonly(database, "main") == 1 else { throw ReadError.database }
        sqlite3_busy_timeout(database, 1_500)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)

        let schemaVersion = readSchemaVersion(database)
        let maximumIdentityRows = 64
        let maximumTotalRows = 512
        let columns = "host_key, path, name, value, encrypted_value, expires_utc, is_secure"
        let identityRows = try readStoredCookies(
            database,
            sql: """
                SELECT \(columns) FROM cookies
                WHERE host_key IN ('.claude.ai', 'claude.ai')
                  AND name IN ('sessionKey', 'lastActiveOrg')
                LIMIT \(maximumIdentityRows + 1)
                """
        )
        // More than 64 identity rows is not a plausible Chromium cookie jar.
        // Fail closed instead of selecting an arbitrary account from a
        // corrupted or adversarial database.
        guard identityRows.count <= maximumIdentityRows else { throw ReadError.database }
        let generalRows = try readStoredCookies(
            database,
            sql: """
                SELECT \(columns) FROM cookies
                WHERE host_key IN ('.claude.ai', 'claude.ai')
                  AND name NOT IN ('sessionKey', 'lastActiveOrg')
                LIMIT \(maximumTotalRows - maximumIdentityRows)
                """
        )
        return (schemaVersion, identityRows + generalRows)
    }

    private static func readStoredCookies(
        _ database: OpaquePointer,
        sql: String
    ) throws -> [StoredCookie] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ReadError.database }
        defer { sqlite3_finalize(statement) }

        var rows: [StoredCookie] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ReadError.database }
            guard let host = sqliteText(statement, column: 0), host.utf8.count <= 256,
                  let path = sqliteText(statement, column: 1), path.utf8.count <= 4_096,
                  let name = sqliteText(statement, column: 2), name.utf8.count <= 1_024,
                  let plain = sqliteText(statement, column: 3), plain.utf8.count <= 64 * 1_024,
                  let encrypted = sqliteBlob(statement, column: 4, maximum: 64 * 1_024)
            else { continue }
            rows.append(StoredCookie(
                host: host,
                path: path,
                name: name,
                plainValue: plain,
                encryptedValue: encrypted,
                expiresAt: chromiumExpiry(sqlite3_column_int64(statement, 5)),
                isSecure: sqlite3_column_int(statement, 6) != 0
            ))
        }
        return rows
    }

    private static func readSchemaVersion(_ database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM meta WHERE key='version' LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqliteText(statement, column: 0) else { return 0 }
        return Int(value) ?? 0
    }

    private static func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let characters = UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
        return String(validatingCString: characters)
    }

    private static func sqliteBlob(
        _ statement: OpaquePointer,
        column: Int32,
        maximum: Int
    ) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= maximum else { return nil }
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func chromiumExpiry(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let unixSeconds = Double(value) / 1_000_000 - 11_644_473_600
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func keychainSafeStoragePassword() -> Data? {
        guard let password = Usage.runCommand("/usr/bin/security", [
            "find-generic-password", "-s", safeStorageService, "-w",
        ], timeout: 15) else { return nil }
        return Data(password.utf8)
    }

    private static func cookieDecryptionKey() -> Data? {
        guard let password = keychainSafeStoragePassword() else { return nil }
        return deriveCookieKey(password: password)
    }

    static func deriveCookieKey(password: Data) -> Data? {
        guard !password.isEmpty else { return nil }
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: kCCKeySizeAES128)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    guard let derivedBase = derivedBytes.baseAddress,
                          let passwordBase = passwordBytes.baseAddress,
                          let saltBase = saltBytes.baseAddress else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBase.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltBase.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        derivedBase.assumingMemoryBound(to: UInt8.self),
                        kCCKeySizeAES128
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    static func decryptCookie(
        _ encrypted: Data,
        host: String,
        schemaVersion: Int,
        key: Data
    ) -> String? {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8)
                || encrypted.prefix(3) == Data("v11".utf8),
              key.count == kCCKeySizeAES128
        else { return nil }

        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        guard let plaintext = aesCBCDecrypt(ciphertext, key: key, iv: iv) else { return nil }

        let valueData: Data
        if schemaVersion >= 24 {
            guard plaintext.count >= SHA256.byteCount else { return nil }
            let expected = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.prefix(SHA256.byteCount) == expected else { return nil }
            valueData = Data(plaintext.dropFirst(SHA256.byteCount))
        } else {
            valueData = plaintext
        }
        guard valueData.count <= 64 * 1_024,
              let value = String(data: valueData, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128),
              key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128
        else { return nil }

        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        guard let outputBase = outputBytes.baseAddress,
                              let cipherBase = cipherBytes.baseAddress,
                              let keyBase = keyBytes.baseAddress,
                              let ivBase = ivBytes.baseAddress else { return CCCryptorStatus(kCCParamError) }
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBase,
                            key.count,
                            ivBase,
                            cipherBase,
                            ciphertext.count,
                            outputBase,
                            capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved <= capacity else { return nil }
        return Data(output.prefix(moved))
    }

    // MARK: - Claude Desktop User-Agent

    static func userAgent(
        claudeVersion: String?,
        chromeVersion: String?,
        electronVersion: String?
    ) -> String {
        guard let chromeVersion = safeVersion(chromeVersion) else { return fallbackUserAgent }
        var products: [String] = []
        if let claudeVersion = safeVersion(claudeVersion) {
            products.append("Claude/\(claudeVersion)")
        }
        products.append("Chrome/\(chromeVersion)")
        if let electronVersion = safeVersion(electronVersion) {
            products.append("Electron/\(electronVersion)")
        }
        products.append("Safari/537.36")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) "
            + products.joined(separator: " ")
    }

    private static func detectUserAgent(appPath: String) -> String {
        let appBundle = Bundle(path: appPath)
        let claudeVersion = appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let frameworkRoot = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let framework = frameworkRoot.appendingPathComponent("Versions/A")
        let frameworkBundle = Bundle(path: frameworkRoot.path)
        let electronVersion = frameworkBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let binary = framework.appendingPathComponent("Electron Framework").path
        let chromeVersion = binaryVersion(marker: "Chrome/", path: binary)
        return userAgent(
            claudeVersion: claudeVersion,
            chromeVersion: chromeVersion,
            electronVersion: electronVersion
        )
    }

    private final class UserAgentCache: @unchecked Sendable {
        private let lock = NSLock()
        private var appVersion: String?
        private var cachedValue: String?

        func value(appPath: String) -> String {
            let currentVersion = Bundle(path: appPath)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return lock.withLock {
                if let cachedValue, appVersion == currentVersion { return cachedValue }
                let detected = ClaudeDesktopProvider.detectUserAgent(appPath: appPath)
                appVersion = currentVersion
                cachedValue = detected
                return detected
            }
        }
    }

    private static let userAgentCache = UserAgentCache()

    private static func cachedUserAgent(appPath: String) -> String {
        userAgentCache.value(appPath: appPath)
    }

    private static func binaryVersion(marker: String, path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let markerData = Data(marker.utf8)
        var carry = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty
            else { return nil }
            var data = carry
            data.append(chunk)
            if let range = data.range(of: markerData) {
                let tail = data[range.upperBound...].prefix(32)
                let versionBytes = tail.prefix { byte in
                    (byte >= 0x30 && byte <= 0x39) || byte == 0x2E
                }
                let candidate = String(decoding: versionBytes, as: UTF8.self)
                if let version = safeVersion(candidate) { return version }
            }
            carry = Data(data.suffix(max(0, markerData.count - 1)))
        }
    }

    private static func safeVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 32,
              value.range(of: #"^[0-9]+(?:\.[0-9]+)+$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }
}
