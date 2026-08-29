import Foundation
import os

// MARK: - Logging

enum Log {
    static let subsystem = "dev.gonzih.tachyon"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let model = Logger(subsystem: subsystem, category: "model")
    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let presence = Logger(subsystem: subsystem, category: "presence")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

// MARK: - Core value types

/// A single rate-limit window as surfaced to the UI.
struct UsageWindow: Sendable, Equatable, Identifiable, Codable {
    let label: String
    /// Bounded meter, clamped to 0...100 at the provider boundary. Nil for
    /// spend meters.
    let percentUsed: Double?
    /// Unbounded cost meter, in USD. Nil for percent meters.
    let spendUSD: Double?
    /// User-set ceiling the spend is measured against, when any.
    let budgetUSD: Double?
    let resetsAt: Date?

    var id: String { "\(label)-\(resetsAt?.timeIntervalSince1970 ?? -1)" }

    init(label: String, percentUsed: Double, resetsAt: Date?) {
        self.label = label
        self.percentUsed = Usage.clampPercent(percentUsed)
        self.spendUSD = nil
        self.budgetUSD = nil
        self.resetsAt = resetsAt
    }

    init(label: String, spendUSD: Double, resetsAt: Date?) {
        self.label = label
        self.percentUsed = nil
        self.spendUSD = max(0, spendUSD)
        self.budgetUSD = nil
        self.resetsAt = resetsAt
    }

    /// Spend measured against a user-set budget: carries dollars AND a derived
    /// percent, so the ring gets bands and the popover can say "$34.20 of $50".
    /// A budget that is zero, negative, or non-finite is treated as unset.
    init(label: String, spendUSD: Double, budgetUSD: Double?, resetsAt: Date?) {
        self.label = label
        let spend = max(0, spendUSD)
        self.spendUSD = spend
        if let budget = budgetUSD, budget > 0, budget.isFinite {
            self.budgetUSD = budget
            self.percentUsed = Usage.clampPercent(spend / budget * 100)
        } else {
            self.budgetUSD = nil
            self.percentUsed = nil
        }
        self.resetsAt = resetsAt
    }

    /// "$0", "$0.42", "$4.20", "$128" — compact, ring-label sized.
    static func formatSpend(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 10 { return String(format: "$%.2f", usd) }
        if usd < 100 { return String(format: "$%.1f", usd) }
        return "$\(Int(usd.rounded()))"
    }
}

/// One provider's complete reading at a moment in time.
struct UsageSnapshot: Sendable, Equatable, Codable {
    /// Drives the ring.
    let primary: UsageWindow
    /// Popover rows, primary first.
    let windows: [UsageWindow]
    let asOf: Date
    /// Plan/tier string for the popover footer ("Max", "Pro plan"…).
    let detail: String?
}

/// Result of a single `snapshot()` attempt.
enum ProviderState: Sendable, Equatable {
    /// Live data.
    case ok(UsageSnapshot)
    /// Data from a fallback/file stream, or a previous poll we could not refresh.
    case stale(UsageSnapshot, asOf: Date)
    /// Auth-only failure. Carries user-facing guidance.
    case authError(String)
    /// Everything else: network failure, decode drift, missing files.
    case unavailable

    var snapshot: UsageSnapshot? {
        switch self {
        case .ok(let s): return s
        case .stale(let s, _): return s
        case .authError, .unavailable: return nil
        }
    }

    /// When the reading went stale, if it is stale.
    var staleSince: Date? {
        if case .stale(_, let asOf) = self { return asOf }
        return nil
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var isAuthError: Bool {
        if case .authError = self { return true }
        return false
    }

    var authGuidance: String? {
        if case .authError(let g) = self { return g }
        return nil
    }
}

/// Whether a provider is even worth showing.
enum ProviderPresence: Sendable, Equatable {
    /// No trace of the harness on this machine — invisible everywhere but the menu hint.
    case notInstalled
    /// Harness present but no usable credential. Greyed in menu with guidance.
    case notSignedIn(String)
    /// Ready to poll.
    case ready
}

// MARK: - Provider contract

/// Implement this in one file, add one registry line, add one glyph.
/// See CONTRIBUTING.md — `GrokProvider.swift` is the worked example.
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    /// Popover header name — just the product ("Codex"), no suffixes.
    nonisolated var shortName: String { get }
    nonisolated var glyph: ProviderGlyph { get }
    nonisolated var pollInterval: TimeInterval { get }
    /// Marks the provider as unverified/experimental in the UI.
    nonisolated var isExperimental: Bool { get }
    /// Optional one-line description — shown on hover in the menu and in the
    /// provider's Settings pane. Useful when the name alone doesn't explain
    /// what's being metered (corporate accounts, aggregators…).
    nonisolated var about: String? { get }
    /// Files/directories to watch while the provider is enabled. The app owns
    /// the FSEvents machinery: on any change it calls `fileChanged(_:)` with
    /// the triggering path, then re-polls the provider. Empty = no watching.
    nonisolated var watchPaths: [String] { get }
    /// Declared, optional refinements — rendered generically by the Settings
    /// window. Defaults must always leave the provider fully functional.
    nonisolated var settings: [ProviderSetting] { get }

    func detect() async -> ProviderPresence
    func snapshot() async -> ProviderState

    /// Invoked with the path that triggered a watch event, before the re-poll.
    /// Use it to invalidate caches; the fresh snapshot() follows automatically.
    func fileChanged(_ path: String) async
}

extension UsageProvider {
    nonisolated var isExperimental: Bool { false }
    nonisolated var shortName: String { displayName }
    nonisolated var settings: [ProviderSetting] { [] }
    nonisolated var about: String? { nil }
    nonisolated var watchPaths: [String] { [] }
    func fileChanged(_ path: String) async {}
}

// MARK: - Registry

/// One declared provider setting. `key` is a SUFFIX — the app composes the
/// full UserDefaults key as "provider.<providerID>.<key>" (distinct from the
/// legacy "provider.enabled.<id>" keys, which are not migrated).
struct ProviderSetting: Sendable, Identifiable, Equatable {
    let key: String
    let title: String
    let help: String?
    let kind: Kind

    var id: String { key }

    enum Kind: Sendable, Equatable {
        /// Stored in Tachyon's own Keychain item — never UserDefaults, never
        /// logs, never smoke output.
        case secret(placeholder: String)
        case money(defaultValue: Double?)
        case toggle(defaultValue: Bool)
        case choice(options: [String], defaultValue: String)
    }
}

enum ProviderRegistry {
    /// Add your provider here.
    static let all: [any UsageProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        GrokProvider(),
        CursorProvider(),
        OmpProvider(),
        OpenRouterProvider(),
    ]
}

// MARK: - Shared helpers

enum Usage {
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// Home-relative path resolution honoring an optional environment override.
    static func homePath(_ components: String...) -> String {
        var url = URL(fileURLWithPath: NSHomeDirectory())
        for component in components { url.appendPathComponent(component) }
        return url.path
    }

    static func env(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Shared, cookie-less session with short timeouts. Private APIs — no caching.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct HTTPResult: Sendable {
        let status: Int
        let body: Data
    }

    /// Performs a GET, surfacing the status code rather than throwing on 4xx/5xx.
    static func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResult(status: status, body: data)
    }

    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResult(status: status, body: data)
    }

    /// Reads the final `byteCount` bytes of a file, discarding the (likely partial)
    /// first line. Returns complete lines only, oldest first.
    static func tailLines(path: String, byteCount: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(byteCount) ? size - UInt64(byteCount) : 0

            // If the byte just before the read starts is a newline, the tail
            // begins exactly on a record boundary and the first line is whole —
            // discarding it would silently drop the record we most want.
            var startsOnBoundary = false
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                if let prefix = try handle.read(upToCount: 1), prefix.first == 0x0A {
                    startsOnBoundary = true
                }
            }

            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return [] }
            guard var text = String(data: data, encoding: .utf8) else {
                // Tail may have sliced a multi-byte scalar; drop leading bytes until valid.
                var slice = data
                var attempts = 0
                while attempts < 4, !slice.isEmpty {
                    slice = slice.dropFirst()
                    attempts += 1
                    if let recovered = String(data: slice, encoding: .utf8) {
                        return splitTail(recovered, truncated: true)
                    }
                }
                return []
            }
            if offset > 0 {
                text = String(text)
                return splitTail(text, truncated: !startsOnBoundary)
            }
            return splitTail(text, truncated: false)
        } catch {
            return []
        }
    }

    private static func splitTail(_ text: String, truncated: Bool) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A tail read almost certainly begins mid-line: discard through the first newline.
        if truncated, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Decodes the payload segment of a JWT without verifying the signature.
    /// Used only for non-authoritative metadata (plan name, `exp`).
    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func jwtExpiry(_ token: String) -> Date? {
        guard let payload = decodeJWTPayload(token) else { return nil }
        if let exp = payload["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = payload["exp"] as? Int { return Date(timeIntervalSince1970: Double(exp)) }
        return nil
    }

    /// Runs a short-lived command, returning trimmed stdout when it exits 0.
    ///
    /// stderr goes to `/dev/null` rather than a pipe: draining stdout to EOF
    /// before reading a stderr pipe deadlocks as soon as the child writes more
    /// than the ~64KB pipe buffer to stderr. We never used that output anyway.
    /// A watchdog kills a child that wedges, so an actor can never block forever.
    static func runCommand(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 10
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

// MARK: - Lenient JSON access

/// Optional-tolerant reader over `JSONSerialization` output. Every accessor
/// returns nil rather than throwing, so schema drift degrades to `.unavailable`
/// instead of crashing.
struct JSONValue {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    static func parse(_ data: Data) -> JSONValue {
        JSONValue(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSONValue {
        JSONValue((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSONValue {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return JSONValue(nil) }
        return JSONValue(array[index])
    }

    var array: [JSONValue] {
        (raw as? [Any])?.map(JSONValue.init) ?? []
    }

    var dictionary: [String: JSONValue] {
        (raw as? [String: Any])?.mapValues(JSONValue.init) ?? [:]
    }

    var isNull: Bool { raw == nil || raw is NSNull }
    var exists: Bool { !isNull }

    var string: String? {
        if let value = raw as? String { return value }
        return nil
    }

    var double: Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    var int: Int? {
        guard let value = double, value.isFinite else { return nil }
        return Int(value)
    }

    var bool: Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return nil
    }

    /// Unix epoch seconds → Date.
    var epochDate: Date? {
        guard let value = double, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// ISO8601 with or without fractional seconds.
    var isoDate: Date? {
        guard let text = string else { return nil }
        return DateParsing.iso8601(text)
    }
}

enum DateParsing {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func iso8601(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
