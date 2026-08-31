import CoreFoundation
import CryptoKit
import Darwin
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
    /// A projection needs enough calendar history before it may alter color or
    /// animate. A qualitative early warning has a separate quota threshold so
    /// a substantial first burst is still visible to someone managing runway.
    private static let stablePaceElapsedFraction = 0.1
    private static let earlyPacePercentThreshold = 10.0

    let label: String
    /// Bounded meter, clamped to 0...100 at the provider boundary. Nil for
    /// spend meters.
    let percentUsed: Double?
    /// Unbounded cost meter, in USD. Nil for percent meters.
    let spendUSD: Double?
    /// User-set ceiling the spend is measured against, when any.
    let budgetUSD: Double?
    /// Unbounded count meter (requests, runs…). Nil for other meters.
    let count: Int?
    /// Unit label for `count` ("requests"). Nil unless `count` is set.
    let countUnit: String?
    let resetsAt: Date?
    /// Full window duration in seconds (5h session = 18000, weekly = 604800).
    /// Enables the pace projection; nil when the provider doesn't know it.
    let windowSeconds: Double?

    var id: String { "\(label)-\(resetsAt?.timeIntervalSince1970 ?? -1)" }

    init(label: String, percentUsed: Double, resetsAt: Date?, windowSeconds: Double? = nil) {
        self.label = label
        self.percentUsed = Usage.clampPercent(percentUsed)
        self.spendUSD = nil
        self.budgetUSD = nil
        self.count = nil
        self.countUnit = nil
        self.resetsAt = resetsAt
        self.windowSeconds = Usage.positiveFinite(windowSeconds)
    }

    init(label: String, spendUSD: Double, resetsAt: Date?) {
        self.label = label
        self.percentUsed = nil
        self.spendUSD = Usage.nonnegativeFinite(spendUSD)
        self.budgetUSD = nil
        self.count = nil
        self.countUnit = nil
        self.resetsAt = resetsAt
        self.windowSeconds = nil
    }

    /// Observed activity with no denominator: "42 requests".
    init(label: String, count: Int, unit: String, resetsAt: Date?) {
        self.label = label
        self.percentUsed = nil
        self.spendUSD = nil
        self.budgetUSD = nil
        self.count = max(0, count)
        self.countUnit = unit
        self.resetsAt = resetsAt
        self.windowSeconds = nil
    }

    /// Spend measured against a user-set budget: carries dollars AND a derived
    /// percent, so the ring gets bands and the popover can say "$34.20 of $50".
    /// A budget that is zero, negative, or non-finite is treated as unset.
    init(label: String, spendUSD: Double, budgetUSD: Double?, resetsAt: Date?) {
        self.label = label
        let spend = Usage.nonnegativeFinite(spendUSD)
        self.spendUSD = spend
        if let budget = budgetUSD, budget > 0, budget.isFinite {
            self.budgetUSD = budget
            self.percentUsed = Usage.clampPercent(spend / budget * 100)
        } else {
            self.budgetUSD = nil
            self.percentUsed = nil
        }
        self.count = nil
        self.countUnit = nil
        self.resetsAt = resetsAt
        self.windowSeconds = nil
    }

    // MARK: Pace (CONTRIBUTING §"The ring rule")

    /// The raw point-in-time projection and its elapsed-window fraction. It is
    /// intentionally private: early samples can inform a qualitative warning,
    /// but only a settled sample may drive a number, color escalation, or a
    /// pulse.
    private var paceSample: (projected: Double, elapsedFraction: Double)? {
        guard let percent = percentUsed, let seconds = windowSeconds, seconds > 0,
              let resets = resetsAt else { return nil }
        let remaining = resets.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0, remaining < seconds else { return nil }
        let elapsedFraction = 1 - remaining / seconds
        guard elapsedFraction > 0 else { return nil }
        return (percent / elapsedFraction, elapsedFraction)
    }

    /// The percent this window will reach by its reset if the current burn
    /// rate holds: `percentUsed ÷ elapsed fraction of the window`. Nil without
    /// a known duration and a future reset, or until 10% of the calendar
    /// window has elapsed. Stable projections drive color and animation.
    var projectedAtReset: Double? {
        guard let sample = paceSample,
              sample.elapsedFraction >= Self.stablePaceElapsedFraction
        else { return nil }
        return sample.projected
    }

    /// A substantial amount already spent near the start of a real provider
    /// window is useful runway information even before its rate is stable. It
    /// may show the qualitative limit warning, but never changes color/pulse.
    fileprivate var hasEarlyLimitRisk: Bool {
        guard let percent = percentUsed,
              percent >= Self.earlyPacePercentThreshold,
              let sample = paceSample,
              sample.elapsedFraction < Self.stablePaceElapsedFraction
        else { return false }
        return sample.projected >= 100
    }

    /// On pace to exhaust before the reset. Drives band escalation and the
    /// pulse on ring, shim, and popover bars. A fully exhausted account stays
    /// hot because moving work to another available source is still a useful
    /// decision in a capacity-optimization tool.
    var isPaceHot: Bool {
        // A user-authored spend budget is a planning aid, not a provider hard
        // wall. It may turn red at 100%, but must never pulse or claim that a
        // service limit was reached.
        guard spendUSD == nil, let percent = percentUsed else { return false }
        if percent >= 100 { return true }
        return (projectedAtReset ?? 0) >= 100
    }

    /// What the color bands judge: the raw percent, lifted to the NEXT band's
    /// floor when the window is on pace to exhaust before it resets
    /// (projection ≥ 100). One band, never more — pace is a warning, not a
    /// measurement. Displayed numbers stay `percentUsed`; only color moves.
    var bandPercent: Double? {
        guard let percent = percentUsed else { return nil }
        guard isPaceHot else { return percent }
        switch percent {
        case ..<50: return 50   // green → yellow
        case ..<70: return 70   // yellow → orange
        case ..<90: return 90   // orange → red
        default: return percent // already red
        }
    }

    /// "$0", "$0.42", "$4.20", "$128" — compact, ring-label sized.
    static func formatSpend(_ usd: Double) -> String {
        let value = Usage.nonnegativeFinite(usd)
        if value == 0 { return "$0" }
        if value < 10 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        guard value < Double(Int.max) else { return "$\(String(format: "%.2g", value))" }
        return "$\(Int(value.rounded()))"
    }
}

/// One pure pace decision shared by every visual surface. Keeping stale gating
/// here prevents a future ring, shim, or detail row from accidentally pulsing
/// or projecting from a fallback reading.
struct PacePresentation: Equatable {
    let caption: String?
    let bandPercent: Double?
    let isHot: Bool

    init(window: UsageWindow, isStale: Bool) {
        caption = isStale ? nil : PaceFormat.caption(for: window)
        bandPercent = isStale ? window.percentUsed : window.bandPercent
        isHot = !isStale && window.isPaceHot
    }
}

enum PaceFormat {
    static func caption(for window: UsageWindow) -> String? {
        guard window.spendUSD == nil, let percent = window.percentUsed else { return nil }
        if percent >= 100 { return "Limit reached" }
        if let projected = window.projectedAtReset {
            if projected >= 100 { return "At this pace, limit before reset" }
            return "At this pace, ~\(Int(projected.rounded()))% by reset"
        }
        return window.hasEarlyLimitRisk ? "At this pace, limit before reset" : nil
    }
}

extension Array where Element == UsageWindow {
    /// Worst-active-bounded-window rule (CONTRIBUTING §"The ring rule"): the
    /// ring must show the constraint closest to blocking the user — the
    /// highest percent among HARD windows (real provider limits, percent-only).
    /// Spend meters and budget-derived percents (`spendUSD != nil`) are
    /// synthetic and never outrank a hard window. Moves the worst hard window
    /// to the front — index 0 is the ring — leaving the rest in given order.
    func worstFirst() -> [UsageWindow] {
        var worstIndex: Int?
        for (index, window) in enumerated()
        where window.spendUSD == nil && window.percentUsed != nil {
            if worstIndex == nil
                || (window.percentUsed ?? 0) > (self[worstIndex!].percentUsed ?? 0) {
                worstIndex = index
            }
        }
        guard let worstIndex, worstIndex != 0 else { return self }
        var reordered = self
        reordered.insert(reordered.remove(at: worstIndex), at: 0)
        return reordered
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
    /// Current data: a live response or a freshly emitted provider observation.
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

/// One scheduler result: usage state and the verified pool identity derived
/// from the exact credential/session material that produced it. Keeping these
/// together prevents an account switch between separate async calls from
/// pairing account A's numbers with account B's identity.
struct ProviderReading: Sendable, Equatable {
    let state: ProviderState
    let accountFingerprint: String?
}

/// Whether a provider is even worth showing.
enum ProviderPresence: Sendable, Equatable {
    /// No trace of the harness on this machine — invisible everywhere but the menu hint.
    case notInstalled
    /// Harness present but no usable credential. Labeled in the menu with guidance.
    case notSignedIn(String)
    /// Ready to poll.
    case ready
}

// MARK: - Provider contract

/// Implement this in one file, add one registry line, add one glyph.
/// See CONTRIBUTING.md — `GrokProvider.swift` is the worked example.
///
/// MAINTENANCE INVARIANT: provider code is intentionally more explicit than
/// ordinary application code. Its branches encode real differences between
/// app versions, install locations, credential owners, file layouts, retry
/// classes, and incomplete payloads seen across users' machines. Complexity
/// work may extract and name those branches; it must not erase candidates,
/// collapse auth and I/O failures, or replace bounded fallback chains with a
/// path that merely works on the maintainer's current machine.
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    /// Popover header name — just the product ("Codex"), no suffixes.
    nonisolated var shortName: String { get }
    /// Which product surface produced this reading (for example "Code", "CLI",
    /// or "Desktop"). Nil when the provider has only one source or the
    /// distinction would not help the user. Labels never imply source merging.
    nonisolated var sourceLabel: String? { get }
    nonisolated var glyph: ProviderGlyph { get }
    nonisolated var pollInterval: TimeInterval { get }
    /// Optional UI-only grace before a failed-refresh reading is visibly
    /// labeled stale. The state remains `.stale` immediately, so backoff runs
    /// and pace effects stay disabled; this only avoids shouting about one
    /// expected missed poll on endpoints with tight shared rate limits.
    nonisolated var staleIndicatorDelay: TimeInterval { get }
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
    /// Menu/Settings grouping. Defaulted to `.subscription`.
    nonisolated var category: ProviderCategory { get }
    /// Declarative fields rendered generically by Settings. Non-secret
    /// refinements should have neutral defaults; a provider may require a
    /// secret when no safe local credential source exists.
    nonisolated var settings: [ProviderSetting] { get }

    func detect() async -> ProviderPresence
    func snapshot() async -> ProviderState

    /// Scheduler-facing atomic result. The default is identity-less; a source
    /// that must guard against a local account switch overrides this and binds
    /// its ephemeral opaque fingerprint to the same material used by
    /// `snapshot()`. Fingerprints never merge sources.
    func reading() async -> ProviderReading

    /// Lets a provider reject unrelated events when it must watch a shared
    /// parent directory. This runs before cache invalidation and re-polling.
    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool

    /// Invoked with the path that triggered a watch event, before the re-poll.
    /// Use it to invalidate caches; the fresh snapshot() follows automatically.
    func fileChanged(_ path: String) async
}

extension UsageProvider {
    nonisolated var isExperimental: Bool { false }
    nonisolated var shortName: String { displayName }
    nonisolated var sourceLabel: String? { nil }
    nonisolated var staleIndicatorDelay: TimeInterval { 0 }
    nonisolated var settings: [ProviderSetting] { [] }
    nonisolated var about: String? { nil }
    nonisolated var watchPaths: [String] { [] }
    nonisolated var category: ProviderCategory { .subscription }
    func reading() async -> ProviderReading {
        ProviderReading(state: await snapshot(), accountFingerprint: nil)
    }
    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool { true }
    func fileChanged(_ path: String) async {}
}

// MARK: - Registry

/// Where a provider sits in menus and the Settings sidebar. Order here is
/// display order.
enum ProviderCategory: Int, Sendable, Comparable, Equatable {
    /// Subscription coding surfaces (Claude Code/Desktop, Codex CLI/Desktop,
    /// Grok, Cursor).
    case subscription
    /// Open harnesses that route to many providers (Oh My Pi).
    case openHarness
    /// Model infrastructure and routers (OpenRouter, Ollama).
    case infrastructure

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

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
        ClaudeDesktopProvider(),
        CodexProvider(),
        CodexDesktopProvider(),
        GrokProvider(),
        CursorProvider(),
        OmpProvider(),
        OpenRouterProvider(),
        OllamaProvider(),
    ]
}

// MARK: - Shared helpers

enum Usage {
    private static let httpTokenPunctuation = Set("!#$%&'*+-.^_`|~".utf8)

    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    static func nonnegativeFinite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
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

    /// Reads a small local config/credential file without trusting its size.
    /// Provider files are tiny in normal operation; an oversized or racing
    /// file degrades to missing instead of creating an unbounded allocation.
    static func boundedFile(path: String, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max,
              let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size <= UInt64(maximumBytes) else { return nil }
            try handle.seek(toOffset: 0)
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 64 * 1024))
            while data.count <= maximumBytes {
                let remaining = maximumBytes - data.count + 1
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data.count <= maximumBytes ? data : nil
        } catch {
            return nil
        }
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

    enum HTTPRequestError: Error {
        case invalidHeader
        case responseTooLarge
    }

    static let maximumHTTPResponseBytes = 4 * 1024 * 1024

    /// Foundation expects already-valid HTTP field names and values. Provider
    /// credentials come from local files/Keychain items, so reject corrupt or
    /// adversarial control bytes instead of handing them to `URLRequest`.
    /// Everything Tachyon sends is intentionally ASCII; the size cap also
    /// prevents a malformed local credential from becoming a huge request.
    static func headersAreSafe(_ headers: [String: String]) -> Bool {
        return headers.allSatisfy { name, value in
            let nameBytes = name.utf8
            guard !nameBytes.isEmpty, nameBytes.count <= 256,
                  nameBytes.allSatisfy({ byte in
                      (byte >= 0x30 && byte <= 0x39)
                          || (byte >= 0x41 && byte <= 0x5A)
                          || (byte >= 0x61 && byte <= 0x7A)
                          || httpTokenPunctuation.contains(byte)
                  })
            else { return false }

            let valueBytes = value.utf8
            return valueBytes.count <= 128 * 1024
                && valueBytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        }
    }

    /// Performs a GET, surfacing the status code rather than throwing on 4xx/5xx.
    static func get(_ url: URL, headers: [String: String]) async throws -> HTTPResult {
        guard headersAreSafe(headers) else { throw HTTPRequestError.invalidHeader }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResult {
        guard headersAreSafe(headers) else { throw HTTPRequestError.invalidHeader }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> HTTPResult {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > maximumHTTPResponseBytes {
            bytes.task.cancel()
            throw HTTPRequestError.responseTooLarge
        }
        let data: Data
        do {
            data = try await boundedData(
                from: bytes,
                maximumBytes: maximumHTTPResponseBytes
            )
        } catch {
            bytes.task.cancel()
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResult(status: status, body: data)
    }

    static func boundedData<Bytes: AsyncSequence>(
        from bytes: Bytes,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes > 0 else { throw HTTPRequestError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw HTTPRequestError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    /// Reads the final `byteCount` bytes of a file, discarding the (likely partial)
    /// first line. Returns complete lines only, oldest first.
    static func tailLines(path: String, byteCount: Int) -> [String] {
        guard byteCount > 0, byteCount <= 16 * 1024 * 1024 else { return [] }
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
            // The file can grow after `seekToEnd()`. Read only the promised
            // tail budget instead of chasing a concurrently appended EOF.
            guard let data = try handle.read(upToCount: byteCount) else { return [] }
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
        guard token.utf8.count <= 256 * 1024 else { return nil }
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
        timeout: TimeInterval = 10,
        maximumOutputBytes: Int = 1024 * 1024
    ) -> String? {
        guard maximumOutputBytes > 0 else { return nil }
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

        let boundedTimeout = timeout.isFinite ? min(max(0.1, timeout), 120) : 10
        let watchdog = DispatchWorkItem {
            // SIGTERM is advisory and a wedged helper can ignore it. SIGKILL
            // makes the timeout a real upper bound for the actor calling us.
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + boundedTimeout,
            execute: watchdog
        )

        var data = Data()
        data.reserveCapacity(min(maximumOutputBytes, 64 * 1024))
        var exceededOutputLimit = false
        while true {
            let chunk: Data
            do {
                guard let next = try out.fileHandleForReading.read(upToCount: 64 * 1024),
                      !next.isEmpty else { break }
                chunk = next
            } catch {
                exceededOutputLimit = true
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            guard chunk.count <= maximumOutputBytes - data.count else {
                exceededOutputLimit = true
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        watchdog.cancel()

        guard !exceededOutputLimit, process.terminationStatus == 0 else { return nil }
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
        let value: Double?
        if let number = raw as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else if let text = raw as? String {
            value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    var int: Int? {
        guard let value = double,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    var bool: Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Unix epoch seconds → Date.
    var epochDate: Date? {
        guard let value = double, value > 0,
              value <= Date.distantFuture.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// ISO8601 with or without fractional seconds.
    var isoDate: Date? {
        guard let text = string else { return nil }
        return DateParsing.iso8601(text)
    }
}

/// Produces equality-comparable account keys without retaining identifiers.
/// The random HMAC key lives for one process only, so fingerprints cannot be
/// correlated across launches or recovered from UserDefaults/logs.
enum OpaqueAccountIdentity {
    private static let key = SymmetricKey(size: .bits256)

    static func fingerprint(namespace: String, components: [String]) -> String? {
        let values = ([namespace] + components).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
        }
        guard values.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Length framing makes component boundaries unambiguous even if a
        // future identifier can contain a separator byte.
        var message = Data()
        for value in values {
            let encoded = Data(value.utf8)
            message.append(Data(String(encoded.count).utf8))
            message.append(0x3A) // ":"
            message.append(encoded)
        }
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
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
