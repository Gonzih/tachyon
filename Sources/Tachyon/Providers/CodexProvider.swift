import Foundation

/// Codex CLI usage from two streams:
///
/// - **Stream A** (`wham/usage`) is the pollable source of truth.
/// - **Stream B** tail-parses the newest rollout JSONL and serves as the offline
///   fallback *and* as a change signal: a completed turn writes a `token_count`
///   event, which fires an immediate Stream A poll via the FSEvents watcher.
actor CodexProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex CLI"
    nonisolated let shortName = "Codex"
    nonisolated let glyph = ProviderGlyph.codex
    nonisolated let pollInterval: TimeInterval = 60

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authGuidance = "Run `codex login`"
    private static let maxRolloutFiles = 5
    /// Day directories to sweep before ranking by mtime — see `newestRolloutFiles`.
    private static let maxDayDirectories = 5
    private static let tailBytes = 256 * 1024

    private var watcher: FSEventsWatcher?

    private struct Auth: Sendable {
        let accessToken: String
        let accountID: String?
        let planType: String?
    }

    // MARK: - Paths

    private static var home: String {
        Usage.env("CODEX_HOME") ?? Usage.homePath(".codex")
    }

    private static var authPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("auth.json").path
    }

    private static var sessionsPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("sessions").path
    }

    // MARK: - Lifecycle

    func start(onExternalChange: @escaping @Sendable () -> Void) async {
        guard watcher == nil else { return }
        let watcher = FSEventsWatcher(path: Self.sessionsPath, latency: 2.0, onChange: onExternalChange)
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        let installed = Usage.fileExists(Self.home)
        guard installed else { return .notInstalled }
        guard Self.loadAuth() != nil else { return .notSignedIn("Run `codex login`") }
        return .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let auth = Self.loadAuth() else {
            // Signed out but installed: rollout files may still carry usable history.
            if let fallback = Self.rolloutSnapshot(planType: nil) {
                return .stale(fallback, asOf: fallback.asOf)
            }
            return .authError(Self.authGuidance)
        }

        do {
            let result = try await Usage.get(Self.usageURL, headers: [
                "Authorization": "Bearer \(auth.accessToken)",
                "ChatGPT-Account-Id": auth.accountID ?? "",
                "Content-Type": "application/json",
            ])

            if result.status == 401 || result.status == 403 {
                // No token refresh in v1. Fall back to the log before declaring auth failure.
                if let fallback = Self.rolloutSnapshot(planType: auth.planType) {
                    return .stale(fallback, asOf: fallback.asOf)
                }
                return .authError(Self.authGuidance)
            }

            if (200..<300).contains(result.status),
               let snapshot = Self.decodeUsage(result.body, planType: auth.planType) {
                return .ok(snapshot)
            }
            Log.provider.error("codex usage HTTP \(result.status) or undecodable; trying rollout tail")
        } catch {
            Log.provider.error("codex usage request failed: \(error.localizedDescription, privacy: .public)")
        }

        if let fallback = Self.rolloutSnapshot(planType: auth.planType) {
            return .stale(fallback, asOf: fallback.asOf)
        }
        return .unavailable
    }

    // MARK: - Stream A decoding

    static func decodeUsage(_ data: Data, planType: String?) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        let rateLimit = root["rate_limit"]

        guard let primary = window(from: rateLimit["primary_window"], fallbackLabel: "Current session") else {
            return nil
        }
        var windows = [primary]
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
                    percentUsed: primaryWindow.percentUsed,
                    resetsAt: primaryWindow.resetsAt
                ))
            }
            if let secondaryWindow = window(from: nested["secondary_window"], fallbackLabel: name) {
                windows.append(UsageWindow(
                    label: "\(name) · \(secondaryWindow.label)",
                    percentUsed: secondaryWindow.percentUsed,
                    resetsAt: secondaryWindow.resetsAt
                ))
            }
        }

        let plan = root["plan_type"].string ?? planType
        return UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: Date(),
            detail: plan.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) plan" }
        )
    }

    private static func window(from value: JSONValue, fallbackLabel: String) -> UsageWindow? {
        guard value.exists, let percent = value["used_percent"].double else { return nil }
        let seconds = value["limit_window_seconds"].double
        let resetsAt = value["reset_at"].epochDate
            ?? value["reset_after_seconds"].double.map { Date().addingTimeInterval($0) }
        return UsageWindow(
            label: windowLabel(seconds: seconds) ?? fallbackLabel,
            percentUsed: percent,
            resetsAt: resetsAt
        )
    }

    /// 18000s → "Current session", 604800s → "Weekly", else "Nh window".
    static func windowLabel(seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
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

    // MARK: - Stream B: rollout tail

    /// Reads the last 256KB of the newest rollout files (max 5) and returns the
    /// newest `token_count` event carrying a non-null `rate_limits.primary`.
    static func rolloutSnapshot(planType: String?) -> UsageSnapshot? {
        for path in newestRolloutFiles(limit: maxRolloutFiles) {
            let lines = Usage.tailLines(path: path, byteCount: tailBytes)
            for line in lines.reversed() {
                guard line.contains("token_count") else { continue }
                guard let data = line.data(using: .utf8) else { continue }
                let root = JSONValue.parse(data)
                let payload = root["payload"]
                guard payload["type"].string == "token_count" else { continue }
                let limits = payload["rate_limits"]
                let primaryValue = limits["primary"]
                guard primaryValue.exists, let percent = primaryValue["used_percent"].double else { continue }

                let asOf = root["timestamp"].isoDate ?? Date()
                let primary = UsageWindow(
                    label: rolloutLabel(minutes: primaryValue["window_minutes"].double) ?? "Current session",
                    percentUsed: percent,
                    resetsAt: primaryValue["resets_at"].epochDate
                )
                var windows = [primary]
                let secondaryValue = limits["secondary"]
                if secondaryValue.exists, let secondaryPercent = secondaryValue["used_percent"].double {
                    windows.append(UsageWindow(
                        label: rolloutLabel(minutes: secondaryValue["window_minutes"].double) ?? "Weekly",
                        percentUsed: secondaryPercent,
                        resetsAt: secondaryValue["resets_at"].epochDate
                    ))
                }
                let plan = limits["plan_type"].string ?? planType
                return UsageSnapshot(
                    primary: primary,
                    windows: windows,
                    asOf: asOf,
                    detail: plan.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) plan" }
                )
            }
        }
        return nil
    }

    private static func rolloutLabel(minutes: Double?) -> String? {
        guard let minutes else { return nil }
        return windowLabel(seconds: minutes * 60)
    }

    /// Newest-first rollout paths, walking `sessions/YYYY/MM/DD` without an
    /// exhaustive recursive enumeration of the whole tree.
    static func newestRolloutFiles(limit: Int) -> [String] {
        let manager = FileManager.default
        let root = sessionsPath
        guard manager.fileExists(atPath: root) else { return [] }

        func sortedChildren(_ directory: String) -> [String] {
            let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
            return entries.sorted(by: >).map {
                URL(fileURLWithPath: directory).appendingPathComponent($0).path
            }
        }

        var candidates: [(path: String, modified: Date)] = []
        var daysScanned = 0
        // Descend year → month → day, newest first. The final ranking is by
        // modification time, but the traversal is by filename, so the cutoff has
        // to span several day directories: a resumed older session (or a restored
        // backup) can be the most recently *modified* file while living in an
        // older day folder. Scanning a fixed number of day directories keeps the
        // walk bounded without making the newest day alone decide the result.
        outer: for year in sortedChildren(root) {
            for month in sortedChildren(year) {
                for day in sortedChildren(month) {
                    for file in sortedChildren(day) where file.hasSuffix(".jsonl") {
                        guard URL(fileURLWithPath: file).lastPathComponent.hasPrefix("rollout-") else { continue }
                        let attributes = try? manager.attributesOfItem(atPath: file)
                        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
                        candidates.append((file, modified))
                    }
                    daysScanned += 1
                    if daysScanned >= maxDayDirectories, candidates.count >= limit { break outer }
                }
            }
        }
        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.path)
    }

    // MARK: - Auth

    private static func loadAuth() -> Auth? {
        guard let data = FileManager.default.contents(atPath: authPath) else { return nil }
        let tokens = JSONValue.parse(data)["tokens"]
        guard let accessToken = tokens["access_token"].string, !accessToken.isEmpty else { return nil }

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
        return Auth(accessToken: accessToken, accountID: accountID, planType: planType)
    }
}
