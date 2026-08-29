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
    nonisolated let isExperimental = true
    nonisolated let about: String? =
        "Daemon activity, counted from Ollama's own log. Ollama doesn't expose cloud quota yet — when it does, this becomes a real usage ring."

    /// The daemon appends a line per request; the watcher makes the ring
    /// tick within seconds of activity.
    nonisolated var watchPaths: [String] {
        Self.logPaths.filter(Usage.fileExists).map { (($0 as NSString).deletingLastPathComponent) }
    }

    /// Homebrew service and the Ollama.app both have known log homes.
    private static var logPaths: [String] {
        [
            Usage.env("OLLAMA_LOG_PATH"),
            "/opt/homebrew/var/log/ollama.log",
            Usage.homePath(".ollama/logs/server.log"),
        ].compactMap { $0 }
    }

    private static let tailBytes = 2 * 1024 * 1024

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        guard Usage.fileExists(Usage.homePath(".ollama")) else { return .notInstalled }
        guard Self.logPaths.contains(where: Usage.fileExists) else {
            return .notSignedIn("Start the Ollama server to begin counting")
        }
        return .ready
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let path = Self.logPaths.first(where: Usage.fileExists) else {
            return .unavailable
        }
        let lines = Usage.tailLines(path: path, byteCount: Self.tailBytes)
        let counts = Self.countRequests(lines: lines, now: Date())

        let hour = UsageWindow(label: "Requests · past hour", count: counts.pastHour, unit: "requests", resetsAt: nil)
        let today = UsageWindow(label: "Requests · today", count: counts.today, unit: "requests", resetsAt: nil)

        return .ok(UsageSnapshot(
            primary: hour,
            windows: [hour, today],
            asOf: Date(),
            detail: "local + cloud via daemon"
        ))
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
            guard let date = formatter.date(from: stamp) else { continue }

            if calendar.isDate(date, inSameDayAs: now) { counts.today += 1 }
            if date >= hourAgo && date <= now { counts.pastHour += 1 }
        }
        return counts
    }

    private static let inferencePaths = [
        "\"/api/chat\"", "\"/api/generate\"", "\"/api/embed\"", "\"/api/embeddings\"",
        "\"/v1/chat/completions\"", "\"/v1/completions\"", "\"/v1/embeddings\"",
    ]
}
