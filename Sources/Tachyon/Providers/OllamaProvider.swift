import Foundation

/// Ollama — observed daemon activity. Ollama exposes no account usage API
/// (local or cloud; verified against docs and omp's stub, 2026-08-28), so the
/// only honest meter is what we can see: inference requests counted from the
/// daemon's own log. Cloud-vs-local attribution is impossible from the log
/// (no model names), so the windows are labeled plainly as requests.
actor OllamaProvider: UsageProvider {
    nonisolated let id = "ollama"
    nonisolated let displayName = "Ollama"
    nonisolated let shortName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollama
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let category: ProviderCategory = .infrastructure
    nonisolated let isExperimental = true
    nonisolated let about: String? = "Request counts only; Ollama has no quota API."

    /// The daemon appends a line per request; the watcher makes the ring
    /// tick within seconds of activity.
    nonisolated var watchPaths: [String] {
        let directories = Self.logPaths
            .map { ($0 as NSString).deletingLastPathComponent }
            .filter(Usage.fileExists)
        return Array(Set(directories)).sorted()
    }

    /// Log directories are shared (especially Homebrew's var/log), so reject
    /// events for unrelated files before the model schedules a fresh parse.
    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool {
        Self.changesAffectLogs(changedPaths, logPaths: Self.logPaths)
    }

    /// Homebrew service and the Ollama.app both have known log homes.
    private static var logPaths: [String] {
        [
            Usage.env("OLLAMA_LOG_PATH"),
            "/opt/homebrew/var/log/ollama.log",
            "/usr/local/var/log/ollama.log",
            Usage.homePath(".ollama/logs/server.log"),
        ].compactMap { $0 }
    }

    private static let tailBytes = 2 * 1024 * 1024

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        let activeLog = Self.newestExistingLogPath(in: Self.logPaths)
        let installed = activeLog != nil
            || Usage.fileExists(Usage.homePath(".ollama"))
            || Usage.fileExists("/Applications/Ollama.app")
            || Usage.fileExists(Usage.homePath("Applications/Ollama.app"))
            || Usage.fileExists("/opt/homebrew/bin/ollama")
            || Usage.fileExists("/usr/local/bin/ollama")
        guard installed else { return .notInstalled }
        guard activeLog != nil else {
            return .notSignedIn("Start Ollama")
        }
        return .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let path = Self.newestExistingLogPath(in: Self.logPaths) else {
            return .unavailable
        }
        let lines = Usage.tailLines(path: path, byteCount: Self.tailBytes)
        let counts = Self.countRequests(lines: lines, now: Date())

        let hour = UsageWindow(label: "Past hour", count: counts.pastHour, unit: "requests", resetsAt: nil)
        let today = UsageWindow(label: "Today", count: counts.today, unit: "requests", resetsAt: nil)

        return .ok(UsageSnapshot(
            primary: hour,
            windows: [hour, today],
            asOf: Date(),
            detail: nil
        ))
    }

    /// Selects the log the daemon touched most recently instead of silently
    /// preferring an old environment or Homebrew path by array order.
    static func newestExistingLogPath(
        in paths: [String],
        fileManager: FileManager = .default
    ) -> String? {
        var newest: (path: String, modifiedAt: Date)?
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
            if let current = newest, modifiedAt <= current.modifiedAt {
                continue
            } else {
                newest = (path, modifiedAt)
            }
        }
        return newest?.path
    }

    static func changesAffectLogs(_ changedPaths: [String], logPaths: [String]) -> Bool {
        let logs = Set(logPaths.map(standardizedPath))
        let directories = Set(logs.map { ($0 as NSString).deletingLastPathComponent })
        return changedPaths.lazy.map(standardizedPath).contains {
            logs.contains($0) || directories.contains($0)
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Log parsing

    struct RequestCounts: Equatable {
        var pastHour: Int
        var today: Int
    }

    /// GIN access lines, e.g.
    /// `[GIN] 2026/08/28 - 22:11:14 | 200 | 1.2s | 127.0.0.1 | POST "/api/chat"`.
    /// Counted: 2xx POSTs to inference endpoints (native and OpenAI-compat).
    /// A truncated tail undercounts "today" — acceptable; never overcounts.
    static func countRequests(lines: [String], now: Date) -> RequestCounts {
        var counts = RequestCounts(pastHour: 0, today: 0)
        let calendar = Calendar.current
        let hourAgo = now.addingTimeInterval(-3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        formatter.timeZone = .current

        for line in lines {
            guard line.hasPrefix("[GIN]"), line.contains("POST") else { continue }
            guard Self.inferencePaths.contains(where: { line.contains($0) }) else { continue }
            // Status is the second |-separated field.
            let fields = line.split(separator: "|", maxSplits: 2)
            guard fields.count >= 2,
                  let status = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  (200..<300).contains(status) else { continue }
            let stamp = fields[0]
                .replacingOccurrences(of: "[GIN]", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let date = formatter.date(from: stamp), date <= now else { continue }

            if calendar.isDate(date, inSameDayAs: now) { counts.today += 1 }
            if date >= hourAgo { counts.pastHour += 1 }
        }
        return counts
    }

    private static let inferencePaths = [
        "\"/api/chat\"", "\"/api/generate\"", "\"/api/embed\"", "\"/api/embeddings\"",
        "\"/v1/chat/completions\"", "\"/v1/completions\"", "\"/v1/embeddings\"",
    ]
}
