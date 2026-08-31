@preconcurrency import AppKit
import Darwin
import CoreFoundation
import Foundation

/// One-shot, read-only Codex app-server fallback.
///
/// This deliberately does not let app-server load the user's managed auth:
/// managed `account/rateLimits/read` may proactively rotate OAuth tokens. The
/// child gets an empty, private CODEX_HOME and only the current access token via
/// app-server's process-local `chatgptAuthTokens` bridge. A refresh request from
/// the child is always rejected.
enum CodexAppServerProbe {
    struct Credential: Sendable {
        let accessToken: String
        let accountID: String
        let planType: String?
        let chatGPTBaseURL: String?
    }

    enum ProbeError: Error, Equatable {
        case executableNotFound
        case launchFailed
        case timedOut
        case connectionClosed
        case outputLimitExceeded
        case invalidResponse
        case rpcFailed

        var safeDescription: String {
            switch self {
            case .executableNotFound: "Codex executable not found"
            case .launchFailed: "Codex app-server could not start"
            case .timedOut: "Codex app-server timed out"
            case .connectionClosed: "Codex app-server closed its connection"
            case .outputLimitExceeded: "Codex app-server exceeded its output limit"
            case .invalidResponse: "Codex app-server returned an invalid response"
            case .rpcFailed: "Codex app-server rejected a usage request"
            }
        }
    }

    private static let desktopBundleIdentifier = "com.openai.codex"
    private static let desktopApplicationNames = ["Codex.app", "ChatGPT.app"]
    private static let defaultCLIExecutableURLs = [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
    ]
    private static let maximumLineBytes = 2 * 1_024 * 1_024
    private static let maximumOutputBytes = 8 * 1_024 * 1_024
    private static let maximumRequestBytes = 512 * 1_024
    private static let defaultTimeout: TimeInterval = 12

    /// Desktop bundle lookup and standalone CLI lookup intentionally remain
    /// separate. Their explicit candidates are a portability/safety matrix;
    /// complexity refactors may extract them but must not remove bundle-ID,
    /// system/user Applications, PATH, or dual-Homebrew-prefix coverage.
    static func desktopExecutableURL(
        bundleIdentifierApplicationURL: URL?,
        fileManager: FileManager = .default,
        systemApplicationsDirectory: URL = URL(
            fileURLWithPath: "/Applications",
            isDirectory: true),
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    ) -> URL? {
        var applications: [URL] = []
        if let bundleIdentifierApplicationURL {
            applications.append(bundleIdentifierApplicationURL)
        }
        for name in desktopApplicationNames {
            applications.append(systemApplicationsDirectory.appendingPathComponent(name))
        }
        for name in desktopApplicationNames {
            applications.append(userApplicationsDirectory.appendingPathComponent(name))
        }
        return firstExecutable(
            applications.map {
                $0.appendingPathComponent("Contents/Resources/codex", isDirectory: false)
            },
            fileManager: fileManager)
    }

    @MainActor
    static func installedDesktopExecutableURL(
        fileManager: FileManager = .default
    ) -> URL? {
        desktopExecutableURL(
            bundleIdentifierApplicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: desktopBundleIdentifier),
            fileManager: fileManager)
    }

    static func cliExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallbackExecutableURLs: [URL] = defaultCLIExecutableURLs
    ) -> URL? {
        var candidates: [URL] = []
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("codex"))
        }
        candidates.append(contentsOf: fallbackExecutableURLs)
        return firstExecutable(candidates, fileManager: fileManager)
    }

    private static func firstExecutable(
        _ candidates: [URL],
        fileManager: FileManager
    ) -> URL? {
        var seen = Set<String>()
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            let attributes = try? fileManager.attributesOfItem(atPath: resolved.path)
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  attributes?[.type] as? FileAttributeType == .typeRegular,
                  fileManager.isExecutableFile(atPath: resolved.path)
            else { continue }
            return resolved
        }
        return nil
    }

    static func fetch(
        credential: Credential,
        executable: URL? = nil,
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> UsageSnapshot {
        guard !credential.accessToken.isEmpty, !credential.accountID.isEmpty else {
            throw ProbeError.invalidResponse
        }
        let resolvedExecutable = if let executable {
            executable
        } else if let bundled = await installedDesktopExecutableURL() {
            bundled
        } else {
            cliExecutableURL(environment: environment)
        }
        guard let resolvedExecutable else {
            throw ProbeError.executableNotFound
        }

        return try await Task.detached(priority: .utility) {
            try run(
                credential: credential,
                executable: resolvedExecutable,
                timeout: timeout,
                inheritedEnvironment: environment)
        }.value
    }

    private static func run(
        credential: Credential,
        executable: URL,
        timeout: TimeInterval,
        inheritedEnvironment: [String: String]
    ) throws -> UsageSnapshot {
        let manager = FileManager.default
        let isolatedHome = manager.temporaryDirectory.appendingPathComponent(
            "Tachyon-CodexProbe-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try manager.createDirectory(
                at: isolatedHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedHome.path)
        } catch {
            throw ProbeError.launchFailed
        }
        defer { try? manager.removeItem(at: isolatedHome) }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        var arguments = ["app-server", "--stdio", "-c", "analytics.enabled=false"]
        if let baseURL = credential.chatGPTBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baseURL.isEmpty
        {
            arguments += ["-c", "chatgpt_base_url=\(tomlString(baseURL))"]
        }
        process.arguments = arguments

        var environment: [String: String] = [:]
        for key in [
            "PATH", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "CODEX_CA_CERTIFICATE",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        ] {
            if let value = inheritedEnvironment[key] { environment[key] = value }
        }
        // HOME is isolated too: CODEX_HOME is authoritative, while HOME closes
        // off accidental fallback reads from other user-scoped config stores.
        environment["HOME"] = isolatedHome.path
        environment["TMPDIR"] = isolatedHome.path
        environment["CODEX_HOME"] = isolatedHome.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        let owner = CodexProbeProcessOwner(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading)
        defer { owner.stop() }

        let deadline = CodexProbeDeadline(timeout: timeout)
        let writer = try CodexJSONLineWriter(
            descriptor: inputPipe.fileHandleForWriting.fileDescriptor,
            maximumLineBytes: maximumRequestBytes)
        let reader = CodexJSONLineReader(
            descriptor: outputPipe.fileHandleForReading.fileDescriptor,
            maximumLineBytes: maximumLineBytes,
            maximumTotalBytes: maximumOutputBytes)

        try writer.write([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "tachyon",
                    "title": "Tachyon",
                    "version": appVersion,
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ], deadline: deadline)
        let initialize = try response(
            id: 1,
            reader: reader,
            writer: writer,
            deadline: deadline)
        try requireResult(initialize)

        try writer.write(["method": "initialized"], deadline: deadline)

        var loginParams: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": credential.accessToken,
            "chatgptAccountId": credential.accountID,
        ]
        if let planType = credential.planType, !planType.isEmpty {
            loginParams["chatgptPlanType"] = planType
        }
        try writer.write([
            "id": 2,
            "method": "account/login/start",
            "params": loginParams,
        ], deadline: deadline)
        let login = try response(
            id: 2,
            reader: reader,
            writer: writer,
            deadline: deadline)
        try requireResult(login)

        try writer.write([
            "id": 3,
            "method": "account/rateLimits/read",
        ], deadline: deadline)
        try writer.write([
            "id": 4,
            "method": "account/usage/read",
        ], deadline: deadline)

        let replies = try responses(
            ids: [3, 4],
            requiredID: 3,
            reader: reader,
            writer: writer,
            deadline: deadline)
        guard let rateLimits = replies[3] else { throw ProbeError.invalidResponse }
        try requireResult(rateLimits)
        guard let snapshot = decodeSnapshot(
            rateLimitsResponse: rateLimits,
            usageResponse: replies[4],
            planType: credential.planType,
            asOf: Date())
        else { throw ProbeError.invalidResponse }
        return snapshot
    }

    /// Decodes camelCase app-server payloads without enum-locking plan names or
    /// failing the main limit when one optional side pool drifts.
    static func decodeSnapshot(
        rateLimitsResponse: Data,
        usageResponse: Data?,
        planType: String?,
        asOf: Date
    ) -> UsageSnapshot? {
        let result = JSONValue.parse(rateLimitsResponse)["result"]
        guard result.exists else { return nil }

        let legacy = result["rateLimits"]
        let byID = result["rateLimitsByLimitId"].dictionary
        var mainKey: String?
        var main = legacy
        if let codex = byID["codex"] {
            main = codex
            mainKey = "codex"
        } else if !main.exists, let first = byID.sorted(by: { $0.key < $1.key }).first {
            main = first.value
            mainKey = first.key
        }

        var hardWindows = windows(from: main)
        if hardWindows.isEmpty, mainKey != nil {
            hardWindows = windows(from: legacy)
        }

        for (key, value) in byID.sorted(by: { $0.key < $1.key }) where key != mainKey {
            let sideWindows = windows(from: value)
            guard sideWindows.contains(where: { ($0.percentUsed ?? 0) >= 1 }) else { continue }
            let name = value["limitName"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = (name?.isEmpty == false ? name : nil) ?? key
            hardWindows += sideWindows.map {
                UsageWindow(
                    label: "\(prefix) · \($0.label)",
                    percentUsed: $0.percentUsed ?? 0,
                    resetsAt: $0.resetsAt,
                    windowSeconds: $0.windowSeconds)
            }
        }

        guard !hardWindows.isEmpty else { return nil }
        hardWindows = hardWindows.worstFirst()
        var allWindows = hardWindows

        let resetCredits = result["rateLimitResetCredits"]
        if resetCredits.exists, let count = safeCount(resetCredits["availableCount"]) {
            allWindows.append(UsageWindow(
                label: "Full resets available",
                count: count,
                unit: count == 1 ? "reset" : "resets",
                resetsAt: nil))
        }

        if let usageResponse,
           let activity = latestDailyActivity(from: usageResponse)
        {
            allWindows.append(activity)
        }

        let reportedPlan = main["planType"].string
            ?? legacy["planType"].string
            ?? planType
        return UsageSnapshot(
            primary: hardWindows[0],
            windows: allWindows,
            asOf: asOf,
            detail: formatPlan(reportedPlan))
    }

    static func formatPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 256
        else {
            return nil
        }
        let normalized = raw.lowercased()
        let title: String = switch normalized {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro"
        case "prolite": "Pro Lite"
        case "self_serve_business_prolite": "Business Pro Lite"
        case "team": "Team"
        case "business", "self_serve_business_usage_based": "Business"
        case "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "ent26": "Enterprise"
        case "edu", "education": "Edu"
        case "edu_plus": "Edu Plus"
        case "edu_pro": "Edu Pro"
        default:
            normalized
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        return "\(title) plan"
    }

    private static func windows(from snapshot: JSONValue) -> [UsageWindow] {
        guard snapshot.exists else { return [] }
        return [
            window(from: snapshot["primary"], fallbackLabel: "Current session"),
            window(from: snapshot["secondary"], fallbackLabel: "Weekly"),
        ].compactMap { $0 }
    }

    private static func window(from value: JSONValue, fallbackLabel: String) -> UsageWindow? {
        guard value.exists,
              let percent = value["usedPercent"].double,
              percent.isFinite
        else { return nil }
        let minutes = value["windowDurationMins"].double.flatMap {
            $0.isFinite && $0 > 0 && $0 < Double(Int.max) / 60 ? $0 : nil
        }
        let seconds = minutes.map { $0 * 60 }
        return UsageWindow(
            label: CodexProvider.windowLabel(seconds: seconds) ?? fallbackLabel,
            percentUsed: percent,
            resetsAt: value["resetsAt"].epochDate,
            windowSeconds: seconds)
    }

    private static func latestDailyActivity(from response: Data) -> UsageWindow? {
        let buckets = JSONValue.parse(response)["result"]["dailyUsageBuckets"].array
        let values: [(String, Int)] = buckets.compactMap { bucket in
            guard let date = bucket["startDate"].string,
                  isDateOnly(date),
                  let count = safeCount(bucket["tokens"])
            else { return nil }
            return (date, count)
        }
        guard let latest = values.max(by: { $0.0 < $1.0 }) else { return nil }
        return UsageWindow(
            label: "Tokens · \(latest.0)",
            count: latest.1,
            unit: "tokens",
            resetsAt: nil)
    }

    private static func safeCount(_ value: JSONValue) -> Int? {
        guard let number = value.double,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              number < Double(Int.max)
        else { return nil }
        return Int(number)
    }

    private static func isDateOnly(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2
        else { return false }
        return pieces.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func response(
        id: Int,
        reader: CodexJSONLineReader,
        writer: CodexJSONLineWriter,
        deadline: CodexProbeDeadline
    ) throws -> Data {
        while true {
            let line = try reader.readLine(deadline: deadline)
            let object = try messageObject(line)
            if let method = object["method"] as? String {
                try handleServerMessage(
                    method: method,
                    object: object,
                    writer: writer,
                    deadline: deadline)
                continue
            }
            guard responseID(object["id"]) == id else { continue }
            return line
        }
    }

    private static func responses(
        ids: Set<Int>,
        requiredID: Int,
        reader: CodexJSONLineReader,
        writer: CodexJSONLineWriter,
        deadline: CodexProbeDeadline
    ) throws -> [Int: Data] {
        var found: [Int: Data] = [:]
        while found.count < ids.count {
            do {
                let line = try reader.readLine(deadline: deadline)
                let object = try messageObject(line)
                if let method = object["method"] as? String {
                    try handleServerMessage(
                        method: method,
                        object: object,
                        writer: writer,
                        deadline: deadline)
                    continue
                }
                guard let id = responseID(object["id"]), ids.contains(id) else { continue }
                found[id] = line
            } catch ProbeError.timedOut where found[requiredID] != nil {
                break
            } catch ProbeError.connectionClosed where found[requiredID] != nil {
                break
            }
        }
        guard found[requiredID] != nil else { throw ProbeError.invalidResponse }
        return found
    }

    private static func handleServerMessage(
        method: String,
        object: [String: Any],
        writer: CodexJSONLineWriter,
        deadline: CodexProbeDeadline
    ) throws {
        guard let id = object["id"], !(id is NSNull) else { return }
        let message = method == "account/chatgptAuthTokens/refresh"
            ? "Tachyon never refreshes harness credentials"
            : "Tachyon does not implement this server request"
        try writer.write([
            "id": id,
            "error": [
                "code": method == "account/chatgptAuthTokens/refresh" ? -32603 : -32601,
                "message": message,
            ],
        ], deadline: deadline)
    }

    private static func messageObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.invalidResponse
        }
        return object
    }

    private static func responseID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let number = value.doubleValue
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(Int.min),
                  number < Double(Int.max)
            else { return nil }
            return Int(number)
        }
        return nil
    }

    private static func requireResult(_ data: Data) throws {
        let object = try messageObject(data)
        if let error = object["error"], !(error is NSNull) { throw ProbeError.rpcFailed }
        guard let result = object["result"], !(result is NSNull) else {
            throw ProbeError.invalidResponse
        }
    }
}

/// Monotonic deadline shared by the whole one-shot probe.
private struct CodexProbeDeadline: Sendable {
    private let end: UInt64

    init(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? min(max(0.05, timeout), 60) : 12
        let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max / 2)))
        end = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return 0 }
        let milliseconds = (end - now + 999_999) / 1_000_000
        return Int32(min(milliseconds, UInt64(Int32.max)))
    }
}

/// Deadline-aware app-server stdin. Nonblocking writes plus F_SETNOSIGPIPE
/// prevent a wedged or exited child from stalling or terminating Tachyon.
private final class CodexJSONLineWriter {
    private let descriptor: Int32
    private let maximumLineBytes: Int

    init(descriptor: Int32, maximumLineBytes: Int) throws {
        self.descriptor = descriptor
        self.maximumLineBytes = maximumLineBytes
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0
        else { throw CodexAppServerProbe.ProbeError.launchFailed }
    }

    func write(_ object: [String: Any], deadline: CodexProbeDeadline) throws {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { throw CodexAppServerProbe.ProbeError.invalidResponse }
        data.append(0x0A)
        guard data.count <= maximumLineBytes else {
            throw CodexAppServerProbe.ProbeError.outputLimitExceeded
        }

        var offset = 0
        while offset < data.count {
            let remaining = deadline.remainingMilliseconds
            guard remaining > 0 else { throw CodexAppServerProbe.ProbeError.timedOut }
            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT | POLLHUP | POLLERR),
                revents: 0)
            let pollResult = Darwin.poll(&descriptorState, 1, remaining)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                if pollResult == 0 { throw CodexAppServerProbe.ProbeError.timedOut }
                throw CodexAppServerProbe.ProbeError.connectionClosed
            }

            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw CodexAppServerProbe.ProbeError.connectionClosed
            }
        }
    }
}

/// Bounded JSONL reader. All blocking work runs inside the probe's detached task.
private final class CodexJSONLineReader {
    private enum ReadOutcome {
        case data(Data)
        case endOfFile
        case retryPoll
    }

    private let descriptor: Int32
    private let maximumLineBytes: Int
    private let maximumTotalBytes: Int
    private var totalBytes = 0
    private var buffer = Data()

    init(descriptor: Int32, maximumLineBytes: Int, maximumTotalBytes: Int) {
        self.descriptor = descriptor
        self.maximumLineBytes = maximumLineBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    func readLine(deadline: CodexProbeDeadline) throws -> Data {
        while true {
            if let line = try bufferedLine() { return line }
            try waitUntilReadable(deadline: deadline)
            switch try readChunk() {
            case .data(let chunk): try append(chunk)
            case .endOfFile: return try trailingLine()
            case .retryPoll: continue
            }
        }
    }

    private func bufferedLine() throws -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            guard buffer.count <= maximumLineBytes else {
                throw CodexAppServerProbe.ProbeError.outputLimitExceeded
            }
            return nil
        }
        let length = buffer.distance(from: buffer.startIndex, to: newline)
        guard length <= maximumLineBytes else {
            throw CodexAppServerProbe.ProbeError.outputLimitExceeded
        }
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        return line
    }

    private func waitUntilReadable(deadline: CodexProbeDeadline) throws {
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0)
        var pollResult: Int32
        repeat {
            let remaining = deadline.remainingMilliseconds
            guard remaining > 0 else { throw CodexAppServerProbe.ProbeError.timedOut }
            descriptorState.revents = 0
            pollResult = Darwin.poll(&descriptorState, 1, remaining)
        } while pollResult < 0 && errno == EINTR
        guard pollResult > 0 else {
            if pollResult == 0 { throw CodexAppServerProbe.ProbeError.timedOut }
            throw CodexAppServerProbe.ProbeError.connectionClosed
        }
    }

    private func readChunk() throws -> ReadOutcome {
        while true {
            var chunk = Data(count: 64 * 1_024)
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                chunk.count = count
                return .data(chunk)
            }
            if count == 0 { return .endOfFile }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .retryPoll }
            throw CodexAppServerProbe.ProbeError.connectionClosed
        }
    }

    private func append(_ chunk: Data) throws {
        totalBytes += chunk.count
        guard totalBytes <= maximumTotalBytes else {
            throw CodexAppServerProbe.ProbeError.outputLimitExceeded
        }
        buffer.append(chunk)
    }

    private func trailingLine() throws -> Data {
        guard !buffer.isEmpty else {
            throw CodexAppServerProbe.ProbeError.connectionClosed
        }
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }
}

private final class CodexProbeProcessOwner {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var stopped = false

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
            let end = DispatchTime.now().uptimeNanoseconds + 500_000_000
            while process.isRunning, DispatchTime.now().uptimeNanoseconds < end {
                usleep(10_000)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
