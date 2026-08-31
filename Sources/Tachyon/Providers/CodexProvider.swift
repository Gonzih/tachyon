import Foundation

/// Codex CLI usage from three read-only streams:
///
/// - **Stream A** (`wham/usage`) is the pollable source of truth.
/// - **Stream B** is a safe app-server fallback using process-local external
///   auth in an isolated home. It never gives app-server a refresh token.
/// - **Stream C** tail-parses the newest rollout JSONL and serves as the offline
///   fallback *and* as a change signal: a completed turn writes a `token_count`
///   event, which fires an immediate Stream A poll via the FSEvents watcher.
///
/// The three streams, discovery branches, source-attribution checks, and
/// traversal guards form a portability/safety matrix. Complexity refactors may
/// extract and name them, but must not delete candidates, attribution, or error
/// distinctions merely because one path works on the maintainer's machine.
actor CodexProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex CLI"
    nonisolated let shortName = "Codex"
    nonisolated let sourceLabel: String? = "CLI"
    nonisolated let glyph = ProviderGlyph.codex
    nonisolated let pollInterval: TimeInterval = 60
    nonisolated let about = "ChatGPT plan usage for the locally signed-in Codex CLI account."

    private static let defaultUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authGuidance = "Run `codex login`"
    private static let maxRolloutFiles = 5
    /// Always sweep at least this many recent day directories before deciding
    /// that enough rollout candidates were found.
    private static let minimumRolloutDayDirectories = 5
    /// A damaged or adversarial tree must not turn fallback discovery into an
    /// unbounded walk. Normal history is far smaller than this ceiling.
    private static let maximumRolloutDayDirectories = 2_048
    private static let tailBytes = 256 * 1024
    private static let sessionMetadataBytes = 64 * 1024
    private static let maxAuthBytes = 1024 * 1024
    private static let maxConfigBytes = 512 * 1024
    private static let maxAccessTokenBytes = 64 * 1024
    private static let maxAccountIDBytes = 8 * 1024
    /// Matches UsageModel's three-poll stale grace for this 60-second source.
    private static let rolloutFreshness: TimeInterval = 180
    private static let maximumFutureClockSkew: TimeInterval = 60

    private struct Auth: Sendable {
        let accessToken: String
        let accountID: String?
        let planType: String?
    }

    enum RolloutSurface: Sendable {
        case cli
        case desktop
    }

    // MARK: - Paths

    private static var home: String {
        Usage.env("CODEX_HOME") ?? Usage.homePath(".codex")
    }

    private static var authPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("auth.json").path
    }

    static var defaultSessionsPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("sessions").path
    }

    private static var configPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("config.toml").path
    }

    /// A completed turn writes a token_count event — the app re-polls us
    /// within seconds instead of waiting out the interval.
    nonisolated var watchPaths: [String] { [Self.defaultSessionsPath, Self.authPath] }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        if Self.loadAuth() != nil { return .ready }
        let recentRollout = Self.recentUnauthenticatedRollout(planType: nil)
        let installed = Usage.fileExists(Self.authPath)
            || recentRollout != nil
            || CodexAppServerProbe.cliExecutableURL() != nil
        guard installed else { return .notInstalled }
        // Keep historical rollout data visible after sign-out. This is
        // explicitly stale and never treated as a live authenticated read.
        return recentRollout == nil
            ? .notSignedIn(Self.authGuidance)
            : .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let auth = Self.loadAuth() else {
            return Self.unauthenticatedState()
        }
        return await authenticatedSnapshot(using: auth)
    }

    func reading() async -> ProviderReading {
        guard let auth = Self.loadAuth() else {
            return ProviderReading(
                state: Self.unauthenticatedState(),
                accountFingerprint: nil
            )
        }
        let state = await authenticatedSnapshot(using: auth)
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        return ProviderReading(
            state: state,
            accountFingerprint: Self.credentialFingerprint(
                accessToken: auth.accessToken,
                accountID: auth.accountID
            )
        )
    }

    private static func unauthenticatedState() -> ProviderState {
        if let fallback = recentUnauthenticatedRollout(planType: nil) {
            return .stale(fallback, asOf: fallback.asOf)
        }
        return .authError(authGuidance)
    }

    private func authenticatedSnapshot(using auth: Auth) async -> ProviderState {

        let baseURL = Self.chatGPTBaseURL()
        let usageURL = Self.usageURL(baseURL: baseURL)
        let headers = Self.requestHeaders(
            accessToken: auth.accessToken,
            accountID: auth.accountID)

        var directWasAuthError = false
        do {
            let result = try await Usage.get(usageURL, headers: headers)

            if result.status == 401 || result.status == 403 {
                directWasAuthError = true
            } else if (200..<300).contains(result.status),
                      let snapshot = Self.decodeUsage(result.body, planType: auth.planType)
            {
                return .ok(snapshot)
            } else {
                Log.provider.error("codex usage HTTP \(result.status) or undecodable; trying safe fallbacks")
            }
        } catch {
            Log.provider.error("codex usage request failed; trying safe fallbacks")
        }

        if let accountID = auth.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty
        {
            do {
                let snapshot = try await CodexAppServerProbe.fetch(credential: .init(
                    accessToken: auth.accessToken,
                    accountID: accountID,
                    planType: auth.planType,
                    chatGPTBaseURL: baseURL))
                return .ok(snapshot)
            } catch let error as CodexAppServerProbe.ProbeError {
                Log.provider.error("codex safe app-server fallback failed: \(error.safeDescription, privacy: .public)")
            } catch {
                Log.provider.error("codex safe app-server fallback failed")
            }
        }

        // Rollout files carry no account identifier. After an account switch,
        // the newest file may belong to the previous login, so an authenticated
        // read must fail closed instead of labeling unbound history as this key.
        return directWasAuthError ? .authError(Self.authGuidance) : .unavailable
    }

    static func credentialFingerprint(accessToken: String, accountID: String?) -> String? {
        guard !accessToken.isEmpty else { return nil }
        var components = [accessToken]
        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            components.append(accountID)
        }
        return OpaqueAccountIdentity.fingerprint(
            namespace: "codex-credential",
            components: components
        )
    }

    // MARK: - Stream A decoding

    static func decodeUsage(_ data: Data, planType: String?) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        let rateLimit = root["rate_limit"]

        var windows: [UsageWindow] = []
        if let primary = window(from: rateLimit["primary_window"], fallbackLabel: "Current session") {
            windows.append(primary)
        }
        if let secondary = window(from: rateLimit["secondary_window"], fallbackLabel: "Weekly") {
            windows.append(secondary)
        }

        for entry in root["additional_rate_limits"].array {
            let name = entry["limit_name"].string
                ?? entry["metered_feature"].string
                ?? "Additional"
            let nested = entry["rate_limit"]
            // Per-model side pools (e.g. "GPT-5.3-Codex-Spark") are noise while
            // untouched — surface them only once they carry real usage.
            let touched = [nested["primary_window"], nested["secondary_window"]]
                .contains { ($0["used_percent"].double ?? 0) >= 1 }
            guard touched else { continue }
            if let primaryWindow = window(from: nested["primary_window"], fallbackLabel: name) {
                windows.append(UsageWindow(
                    label: "\(name) · \(primaryWindow.label)",
                    percentUsed: primaryWindow.percentUsed ?? 0,
                    resetsAt: primaryWindow.resetsAt,
                    windowSeconds: primaryWindow.windowSeconds
                ))
            }
            if let secondaryWindow = window(from: nested["secondary_window"], fallbackLabel: name) {
                windows.append(UsageWindow(
                    label: "\(name) · \(secondaryWindow.label)",
                    percentUsed: secondaryWindow.percentUsed ?? 0,
                    resetsAt: secondaryWindow.resetsAt,
                    windowSeconds: secondaryWindow.windowSeconds
                ))
            }
        }

        // Worst-active-bounded-window rule: the ring is whichever window is
        // closest to blocking, touched per-model side pools included.
        guard !windows.isEmpty else { return nil }
        let ordered = windows.worstFirst()
        let plan = root["plan_type"].string ?? planType
        return UsageSnapshot(
            primary: ordered[0],
            windows: ordered,
            asOf: Date(),
            detail: CodexAppServerProbe.formatPlan(plan)
        )
    }

    private static func window(from value: JSONValue, fallbackLabel: String) -> UsageWindow? {
        guard value.exists,
              let percent = value["used_percent"].double,
              percent.isFinite
        else { return nil }
        let seconds = value["limit_window_seconds"].double.flatMap {
            $0.isFinite && $0 > 0 && $0 < Double(Int.max) ? $0 : nil
        }
        let now = Date()
        let resetsAt = value["reset_at"].epochDate
            ?? value["reset_after_seconds"].double.flatMap {
                $0.isFinite && $0 > 0 && $0 <= Date.distantFuture.timeIntervalSince(now)
                    ? now.addingTimeInterval($0)
                    : nil
            }
        return UsageWindow(
            label: windowLabel(seconds: seconds) ?? fallbackLabel,
            percentUsed: percent,
            resetsAt: resetsAt,
            windowSeconds: seconds
        )
    }

    /// 18000s → "Current session", 604800s → "Weekly", else "Nh window".
    static func windowLabel(seconds: Double?) -> String? {
        guard let seconds,
              seconds.isFinite,
              seconds > 0,
              seconds < Double(Int.max)
        else { return nil }
        switch Int(seconds.rounded()) {
        case 18000: return "Current session"
        case 604800: return "Weekly"
        default:
            let hours = seconds / 3600
            if hours >= 24, (hours / 24).rounded() == hours / 24 {
                let days = Int(hours / 24)
                return days == 1 ? "Daily" : "\(days)d window"
            }
            let rounded = hours < 1 ? String(format: "%.0fm", seconds / 60) : String(format: "%gh", hours)
            return "\(rounded) window"
        }
    }

    // MARK: - Stream C: rollout tail

    /// Reads the last 256KB of the newest rollout files (max 5) and returns the
    /// newest `token_count` event carrying at least one valid rate-limit window.
    static func rolloutSnapshot(
        planType: String?,
        sessionsPath: String? = nil,
        surface: RolloutSurface = .cli,
        eligibleAt: Date? = nil
    ) -> UsageSnapshot? {
        let sessionsPath = sessionsPath ?? Self.defaultSessionsPath
        var candidates: [UsageSnapshot] = []
        let paths = newestRolloutFiles(
            limit: maxRolloutFiles,
            sessionsPath: sessionsPath,
            accepting: { rolloutBelongsToSurface(path: $0, surface: surface) })
        for path in paths {
            let lines = Usage.tailLines(path: path, byteCount: tailBytes)
            for line in lines.reversed() {
                guard let candidate = rolloutCandidate(
                    from: line,
                    planType: planType,
                    eligibleAt: eligibleAt
                ) else { continue }
                candidates.append(candidate)
                break
            }
        }
        return candidates.max(by: { $0.asOf < $1.asOf })
    }

    private static func rolloutCandidate(
        from line: String,
        planType: String?,
        eligibleAt: Date?
    ) -> UsageSnapshot? {
        guard line.contains("token_count"),
              let data = line.data(using: .utf8)
        else { return nil }
        let root = JSONValue.parse(data)
        let payload = root["payload"]
        guard payload["type"].string == "token_count",
              let asOf = root["timestamp"].isoDate
        else { return nil }
        // Filter before choosing the newest timestamp. A damaged or
        // clock-skewed future record must not mask a valid candidate from
        // another rollout file on this or another machine.
        if let eligibleAt,
           !rolloutTimestampIsEligible(asOf, now: eligibleAt) {
            return nil
        }

        let limits = payload["rate_limits"]
        let windows = [
            rolloutWindow(from: limits["primary"], fallbackLabel: "Current session"),
            rolloutWindow(from: limits["secondary"], fallbackLabel: "Weekly"),
        ].compactMap { $0 }.worstFirst()
        guard let primary = windows.first else { return nil }
        let plan = limits["plan_type"].string ?? planType
        return UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: asOf,
            detail: CodexAppServerProbe.formatPlan(plan))
    }

    private static func rolloutBelongsToSurface(
        path: String,
        surface: RolloutSurface
    ) -> Bool {
        let originator = rolloutOriginator(path: path)
        switch surface {
        case .desktop:
            return originator == "Codex Desktop"
        case .cli:
            // Older CLI rollouts may predate originator metadata, so only the
            // exact Desktop marker is excluded from this compatibility path.
            return originator != "Codex Desktop"
        }
    }

    /// Session metadata is written at the start of a rollout. Read only a
    /// bounded prefix so a malformed or concurrently growing JSONL file cannot
    /// turn source attribution into an unbounded allocation.
    static func rolloutOriginator(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: sessionMetadataBytes) else { return nil }
        for line in prefix.split(separator: 0x0A) {
            let root = JSONValue.parse(Data(line))
            guard root["type"].string == "session_meta" else { continue }
            return root["payload"]["originator"].string
        }
        return nil
    }

    static func rolloutIsEligible(
        _ snapshot: UsageSnapshot,
        authenticated: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !authenticated else { return false }
        return rolloutTimestampIsEligible(snapshot.asOf, now: now)
    }

    private static func rolloutTimestampIsEligible(_ asOf: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(asOf)
        return age >= -maximumFutureClockSkew && age < rolloutFreshness
    }

    private static func recentUnauthenticatedRollout(
        planType: String?,
        now: Date = Date()
    ) -> UsageSnapshot? {
        rolloutSnapshot(planType: planType, eligibleAt: now)
    }

    private static func rolloutWindow(from value: JSONValue, fallbackLabel: String) -> UsageWindow? {
        guard value.exists,
              let percent = value["used_percent"].double,
              percent.isFinite
        else { return nil }
        let minutes = value["window_minutes"].double.flatMap {
            $0.isFinite && $0 > 0 && $0 < Double(Int.max) / 60 ? $0 : nil
        }
        return UsageWindow(
            label: rolloutLabel(minutes: minutes) ?? fallbackLabel,
            percentUsed: percent,
            resetsAt: value["resets_at"].epochDate,
            windowSeconds: minutes.map { $0 * 60 })
    }

    private static func rolloutLabel(minutes: Double?) -> String? {
        guard let minutes else { return nil }
        return windowLabel(seconds: minutes * 60)
    }

    /// Newest-first rollout paths, walking `sessions/YYYY/MM/DD` without an
    /// exhaustive recursive enumeration of the whole tree.
    static func newestRolloutFiles(
        limit: Int,
        sessionsPath: String? = nil,
        minimumDayDirectories: Int = minimumRolloutDayDirectories,
        hardMaximumDayDirectories: Int = maximumRolloutDayDirectories,
        accepting: (String) -> Bool = { _ in true }
    ) -> [String] {
        let manager = FileManager.default
        let root = sessionsPath ?? Self.defaultSessionsPath
        guard limit > 0,
              minimumDayDirectories > 0,
              hardMaximumDayDirectories > 0,
              manager.fileExists(atPath: root)
        else { return [] }

        // Descend year → month → day, newest first. The final ranking is by
        // modification time, but the traversal is by filename. Sweep the minimum
        // even when the newest day already has enough files, then continue through
        // sparse days until enough candidates exist. The independent hard ceiling
        // keeps malformed trees bounded without turning the minimum into a cutoff.
        var search = RolloutCandidateSearch(
            minimumDayDirectories: min(minimumDayDirectories, hardMaximumDayDirectories),
            targetCount: limit,
            hardMaximumDayDirectories: hardMaximumDayDirectories)
        collectRolloutCandidates(
            manager: manager,
            root: root,
            search: &search,
            accepting: accepting)
        return search.candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.path)
    }

    private struct RolloutCandidateSearch {
        let minimumDayDirectories: Int
        let targetCount: Int
        let hardMaximumDayDirectories: Int
        var scannedDayDirectories = 0
        var candidates: [(path: String, modified: Date)] = []

        var shouldStop: Bool {
            scannedDayDirectories >= hardMaximumDayDirectories
                || (scannedDayDirectories >= minimumDayDirectories
                    && candidates.count >= targetCount)
        }

        mutating func scan(
            _ day: String,
            manager: FileManager,
            accepting: (String) -> Bool
        ) {
            guard !shouldStop else { return }
            candidates.append(contentsOf: rolloutFiles(in: day, manager: manager).filter {
                accepting($0.path)
            })
            scannedDayDirectories += 1
        }
    }

    private static func collectRolloutCandidates(
        manager: FileManager,
        root: String,
        search: inout RolloutCandidateSearch,
        accepting: (String) -> Bool
    ) {
        for year in sortedChildren(of: root, manager: manager) {
            collectRolloutCandidates(
                in: year,
                manager: manager,
                search: &search,
                accepting: accepting)
            if search.shouldStop { return }
        }
    }

    private static func collectRolloutCandidates(
        in year: String,
        manager: FileManager,
        search: inout RolloutCandidateSearch,
        accepting: (String) -> Bool
    ) {
        for month in sortedChildren(of: year, manager: manager) {
            collectRolloutCandidates(
                inMonth: month,
                manager: manager,
                search: &search,
                accepting: accepting)
            if search.shouldStop { return }
        }
    }

    private static func collectRolloutCandidates(
        inMonth month: String,
        manager: FileManager,
        search: inout RolloutCandidateSearch,
        accepting: (String) -> Bool
    ) {
        for day in sortedChildren(of: month, manager: manager) {
            search.scan(day, manager: manager, accepting: accepting)
            if search.shouldStop { return }
        }
    }

    private static func rolloutFiles(
        in day: String,
        manager: FileManager
    ) -> [(path: String, modified: Date)] {
        var candidates: [(path: String, modified: Date)] = []
        for file in sortedChildren(of: day, manager: manager) {
            guard isRolloutFile(file) else { continue }
            let attributes = try? manager.attributesOfItem(atPath: file)
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            candidates.append((file, modified))
        }
        return candidates
    }

    private static func sortedChildren(of directory: String, manager: FileManager) -> [String] {
        let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        return entries.sorted(by: >).map {
            URL(fileURLWithPath: directory).appendingPathComponent($0).path
        }
    }

    private static func isRolloutFile(_ path: String) -> Bool {
        path.hasSuffix(".jsonl")
            && URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-")
    }

    // MARK: - Endpoint configuration

    static func requestHeaders(accessToken: String, accountID: String?) -> [String: String] {
        var headers = ["Authorization": "Bearer \(accessToken)"]
        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty,
           accountID.utf8.count <= maxAccountIDBytes,
           Usage.headersAreSafe(["ChatGPT-Account-Id": accountID])
        {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

    static func usageURL(baseURL: String?) -> URL {
        guard let base = validatedBaseURL(baseURL),
              var components = URLComponents(string: base),
              let host = components.host?.lowercased()
        else { return defaultUsageURL }
        if (host == "chatgpt.com" || host == "chat.openai.com"),
           !components.path.contains("/backend-api")
        {
            components.path += "/backend-api"
        }
        let suffix = components.path.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        components.path += suffix
        return components.url ?? defaultUsageURL
    }

    /// A custom base receives the current Codex bearer token, so its transport
    /// boundary is deliberately narrow: HTTPS everywhere, or plaintext only
    /// for an explicit numeric/localhost loopback used by local development.
    /// Userinfo, query, and fragment components are never forwarded.
    static func validatedBaseURL(_ rawValue: String?) -> String? {
        var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.utf8.count <= 4 * 1024 else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || (scheme == "http" && isLoopbackHost(host))
        else { return nil }
        components.scheme = scheme
        guard components.url != nil else { return nil }
        return components.string
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets[0] == "127",
              octets.allSatisfy({ part in
                  guard let value = Int(part), (0...255).contains(value) else { return false }
                  return String(value) == part
              })
        else { return false }
        return true
    }

    static func chatGPTBaseURL(configContents: String? = nil) -> String? {
        let contents = configContents ?? Usage.boundedFile(path: configPath, maximumBytes: maxConfigBytes)
            .flatMap { String(data: $0, encoding: .utf8) }
        guard let contents else { return nil }
        var insideTable = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let uncommented = tomlLineWithoutComment(rawLine)
            let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                insideTable = true
                continue
            }
            guard !insideTable else { continue }
            let pieces = uncommented.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2,
                  let quote = value.first,
                  quote == value.last,
                  quote == "\"" || quote == "'"
            else { continue }
            let literal = String(value.dropFirst().dropLast())
            let decoded = quote == "\""
                ? literal
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                : literal
            return validatedBaseURL(decoded)
        }
        return nil
    }

    /// Removes a TOML comment without treating `#` inside a quoted URL as a
    /// comment delimiter. The provider intentionally reads only the root key;
    /// it does not guess which profile table is active.
    private static func tomlLineWithoutComment(_ line: Substring) -> Substring {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
            } else if character == quote {
                quote = nil
            } else if quote == nil, character == "\"" || character == "'" {
                quote = character
            } else if character == "#", quote == nil {
                return line[..<index]
            }
        }
        return line
    }

    // MARK: - Auth

    private static func loadAuth() -> Auth? {
        guard let data = Usage.boundedFile(path: authPath, maximumBytes: maxAuthBytes) else { return nil }
        let tokens = JSONValue.parse(data)["tokens"]
        guard let accessToken = tokens["access_token"].string,
              !accessToken.isEmpty,
              accessToken.utf8.count <= maxAccessTokenBytes
        else { return nil }

        var accountID = tokens["account_id"].string
        var planType: String?
        if let idToken = tokens["id_token"].string,
           let claims = Usage.decodeJWTPayload(idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            planType = auth?["chatgpt_plan_type"] as? String
            if accountID == nil || accountID?.isEmpty == true {
                accountID = auth?["chatgpt_account_id"] as? String
            }
        }
        if let value = accountID, value.utf8.count > maxAccountIDBytes { accountID = nil }
        if let value = planType, value.utf8.count > 256 { planType = nil }
        return Auth(accessToken: accessToken, accountID: accountID, planType: planType)
    }

}
