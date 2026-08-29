import Foundation

/// Grok CLI usage.
///
/// This file is also the worked example in `CONTRIBUTING.md`: a provider is one
/// file conforming to `UsageProvider`, one registry line, one glyph.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok CLI"
    nonisolated let shortName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok
    /// The weekly credit window moves slowly; 120s is plenty.
    nonisolated let pollInterval: TimeInterval = 120

    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let authGuidance = "Run `grok` to refresh sign-in"
    private static let expectedIssuer = "https://auth.x.ai"
    private static let logTailBytes = 8 * 1024 * 1024
    private static let logFreshness: TimeInterval = 300

    private struct Account: Sendable {
        let key: String
        let userID: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    // MARK: - Paths

    private static var home: String {
        Usage.env("GROK_HOME") ?? Usage.homePath(".grok")
    }

    private static var authPath: String {
        Usage.env("GROK_AUTH_JSON")
            ?? URL(fileURLWithPath: home).appendingPathComponent("auth.json").path
    }

    private static var logPath: String {
        URL(fileURLWithPath: home).appendingPathComponent("logs/unified.jsonl").path
    }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        guard Usage.fileExists(Self.home) || Usage.fileExists(Self.authPath) else {
            return .notInstalled
        }
        guard let account = Self.loadAccount() else {
            return .notSignedIn("Run `grok` to sign in")
        }
        if account.isExpired { return .notSignedIn(Self.authGuidance) }
        return .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let account = Self.loadAccount() else {
            if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
            return .authError(Self.authGuidance)
        }
        // No OIDC refresh in v1: the tokens rotate single-use, and racing the CLI
        // for them would break the user's sign-in.
        guard !account.isExpired else {
            if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
            return .authError(Self.authGuidance)
        }

        do {
            var headers = [
                "Authorization": "Bearer \(account.key)",
                "X-XAI-Token-Auth": "xai-grok-cli",
                "User-Agent": "GrokCLI/\(Self.installedVersion() ?? "1.0.0")",
            ]
            if let userID = account.userID { headers["x-userid"] = userID }

            let result = try await Usage.get(Self.billingURL, headers: headers)
            if result.status == 401 || result.status == 403 {
                if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
                return .authError(Self.authGuidance)
            }
            if (200..<300).contains(result.status) {
                let root = JSONValue.parse(result.body)
                if let snapshot = Self.decodeBilling(root["config"], asOf: Date()) {
                    return .ok(snapshot)
                }
            }
            Log.provider.error("grok billing HTTP \(result.status) or undecodable")
        } catch {
            Log.provider.error("grok billing request failed: \(error.localizedDescription, privacy: .public)")
        }

        if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
        return .unavailable
    }

    // MARK: - Decoding

    /// Proto3-JSON: scalar fields at their default value are omitted entirely,
    /// so a missing `creditUsagePercent` means 0 — not missing data. We require
    /// some other recognized field to be present before trusting that reading.
    static func decodeBilling(_ config: JSONValue, asOf: Date) -> UsageSnapshot? {
        guard config.exists else { return nil }

        let knownFields = ["creditUsagePercent", "currentPeriod", "productUsage",
                           "subscriptionTier", "onDemandCap", "onDemandUsed"]
        let present = knownFields.contains { config[$0].exists }
        guard present else { return nil }

        let percent = config["creditUsagePercent"].double ?? 0
        let periodEnd = config["currentPeriod"]["endTime"].isoDate
            ?? config["currentPeriod"]["end"].isoDate
            ?? config["currentPeriod"]["endTime"].epochDate

        let primary = UsageWindow(label: "Credits", percentUsed: percent, resetsAt: periodEnd)
        var windows = [primary]

        for entry in config["productUsage"].array {
            guard let name = entry["productName"].string ?? entry["name"].string else { continue }
            let used = entry["usagePercent"].double ?? entry["creditUsagePercent"].double ?? 0
            windows.append(UsageWindow(label: name, percentUsed: used, resetsAt: periodEnd))
        }

        if let cap = config["onDemandCap"].double, cap > 0 {
            let used = config["onDemandUsed"].double ?? 0
            windows.append(UsageWindow(
                label: "On-demand",
                percentUsed: used / cap * 100,
                resetsAt: periodEnd
            ))
        }

        let tier = config["subscriptionTier"].string
        return UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: asOf,
            detail: tier.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        )
    }

    // MARK: - Stream B: unified log tail

    /// Scans the tail of `logs/unified.jsonl` backwards for the most recent
    /// billing fetch. Only accepted when ≤5 minutes old.
    static func logSnapshot() -> UsageSnapshot? {
        guard Usage.fileExists(logPath) else { return nil }
        let lines = Usage.tailLines(path: logPath, byteCount: logTailBytes)
        for line in lines.reversed() {
            guard line.contains("billing: fetched credits config") else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            let root = JSONValue.parse(data)
            guard root["msg"].string == "billing: fetched credits config" else { continue }
            let asOf = root["time"].isoDate ?? root["ts"].isoDate ?? root["timestamp"].isoDate
            // Keep walking backwards rather than aborting: a record with an
            // unrecognized timestamp key, or one newer than the freshness
            // window is not evidence that no usable record exists further back.
            guard let asOf, Date().timeIntervalSince(asOf) <= logFreshness else { continue }
            guard let snapshot = decodeBilling(root["ctx"]["config"], asOf: asOf) else { continue }
            return snapshot
        }
        return nil
    }

    // MARK: - Auth

    /// `auth.json` is a map of scope key → account record. Only entries issued
    /// by `https://auth.x.ai` are ours; anything else belongs to another product.
    private static func loadAccount() -> Account? {
        guard let data = FileManager.default.contents(atPath: authPath) else { return nil }
        let root = JSONValue.parse(data)
        var best: Account?
        for (_, entry) in root.dictionary {
            guard entry["oidc_issuer"].string == expectedIssuer else { continue }
            guard let key = entry["key"].string, !key.isEmpty else { continue }
            let account = Account(
                key: key,
                userID: entry["user_id"].string,
                expiresAt: Usage.jwtExpiry(key)
            )
            // Prefer a live token over an expired one.
            if best == nil || (best?.isExpired == true && !account.isExpired) {
                best = account
            }
        }
        return best
    }

    /// Best-effort CLI version for the User-Agent; cosmetic only.
    private static func installedVersion() -> String? {
        let candidates = [
            Usage.homePath(".grok", "package.json"),
            "/opt/homebrew/lib/node_modules/@xai-official/grok/package.json",
            "/usr/local/lib/node_modules/@xai-official/grok/package.json",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let version = JSONValue.parse(data)["version"].string { return version }
        }
        return nil
    }
}
