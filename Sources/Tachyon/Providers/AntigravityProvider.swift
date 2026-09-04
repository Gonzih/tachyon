import Foundation

/// Google Antigravity usage through AGY's documented non-interactive
/// `/usage` command. AGY owns its sign-in and makes the request itself;
/// Tachyon neither reads its credentials nor opens its Keychain.
///
/// The returned buckets are account-level and carry no desktop-versus-terminal
/// attribution, so they deliberately form one Antigravity ring rather than
/// two copies of the same allowance.
actor AntigravityProvider: UsageProvider {
    nonisolated let id = "antigravity"
    nonisolated let displayName = "Google Antigravity"
    nonisolated let shortName = "Antigravity"
    nonisolated let glyph = ProviderGlyph.antigravity
    nonisolated let pollInterval: TimeInterval = 120

    static let usageArguments = [
        "--print", "/usage", "--output-format", "json", "--print-timeout", "20s",
    ]

    private static let desktopApplicationPaths = [
        "/Applications/Antigravity.app",
        Usage.homePath("Applications/Antigravity.app"),
    ]

    struct Dependencies: Sendable {
        var findCLI: @Sendable () -> String?
        var isDesktopInstalled: @Sendable () -> Bool
        var fetchUsage: @Sendable (String) async -> Data?
        var now: @Sendable () -> Date

        static let live = Dependencies(
            findCLI: AntigravityProvider.findCLI,
            isDesktopInstalled: {
                AntigravityProvider.desktopApplicationPaths.contains(where: Usage.fileExists)
            },
            fetchUsage: { executable in
                await Task.detached(priority: .utility) {
                    Usage.runCommand(
                        executable,
                        AntigravityProvider.usageArguments,
                        timeout: 25,
                        maximumOutputBytes: 512 * 1024
                    ).map { Data($0.utf8) }
                }.value
            },
            now: Date.init
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func detect() async -> ProviderPresence {
        if dependencies.findCLI() != nil { return .ready }
        return dependencies.isDesktopInstalled()
            ? .notSignedIn("Install AGY CLI to read usage")
            : .notInstalled
    }

    func snapshot() async -> ProviderState {
        guard let executable = dependencies.findCLI(),
              let payload = await dependencies.fetchUsage(executable),
              let snapshot = Self.decodeUsage(payload, asOf: dependencies.now())
        else {
            return .unavailable
        }
        return .ok(snapshot)
    }

    // MARK: - AGY /usage decoding

    static func decodeUsage(_ data: Data, asOf: Date) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        var windows: [UsageWindow] = []

        for group in root["command"]["data"]["groups"].array {
            let groupLabel = quotaGroupLabel(group)
            for bucket in group["buckets"].array {
                guard let remaining = bucket["remaining_fraction"].double,
                      remaining >= 0, remaining <= 1
                else { continue }

                let label = quotaWindowLabel(bucket, group: groupLabel)
                windows.append(UsageWindow(
                    label: label,
                    percentUsed: (1 - remaining) * 100,
                    resetsAt: bucket["reset_time"].isoDate ?? bucket["reset_time"].epochDate,
                    windowSeconds: durationSeconds(bucket["window"])
                ))
            }
        }

        guard !windows.isEmpty else { return nil }
        let ordered = windows.worstFirst()
        return UsageSnapshot(primary: ordered[0], windows: ordered, asOf: asOf, detail: nil)
    }

    private static func findCLI() -> String? {
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let candidates = [
            Usage.homePath(".local/bin/agy"),
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ] + pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("agy").path }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func displayLabel(_ value: String?, fallback: String) -> String {
        let normalized = value?
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(80))
    }

    private static func quotaGroupLabel(_ group: JSONValue) -> String {
        let label = displayLabel(group["name"].string ?? group["label"].string, fallback: "")
        switch label.lowercased() {
        case "gemini models": return "Gemini"
        case "claude and gpt models": return "Claude / GPT"
        case "model quotas", "usage": return ""
        default: return label
        }
    }

    /// The group identifies which models share a quota. Bucket names alone
    /// repeat across groups, and Google's “Remaining” wording contradicts our
    /// percent-used meter. Keep both the pool and neutral period label.
    private static func quotaWindowLabel(_ bucket: JSONValue, group: String) -> String {
        var period = displayLabel(
            bucket["name"].string ?? bucket["description"].string, fallback: "")
        for suffix in [" Limit Remaining", " Remaining"] {
            if period.lowercased().hasSuffix(suffix.lowercased()) {
                period = String(period.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if period.caseInsensitiveCompare("Five Hour") == .orderedSame { period = "5-hour" }
        if group.isEmpty { return period.isEmpty ? "Usage" : period }
        if period.isEmpty || period.caseInsensitiveCompare(group) == .orderedSame { return group }
        return "\(group) · \(period)"
    }

    /// AGY may report a numeric duration or compact, provider-reported units
    /// such as `5h`. Unknown forms intentionally disable pace projection.
    private static func durationSeconds(_ value: JSONValue) -> TimeInterval? {
        if let seconds = value.double, seconds > 0 { return seconds }
        guard let text = value.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), text.count >= 2,
              let unit = text.last,
              let amount = Double(text.dropLast()), amount.isFinite, amount > 0
        else { return nil }

        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 60 * 60
        case "d": multiplier = 24 * 60 * 60
        case "w": multiplier = 7 * 24 * 60 * 60
        default: return nil
        }
        let duration = amount * multiplier
        return duration.isFinite && duration > 0 ? duration : nil
    }
}
