import Darwin
import Foundation

/// Thin bridge to the Homebrew cask that installed Tachyon. Homebrew owns
/// metadata refresh, download verification, installation, and receipts.
struct BrewUpdater: Sendable {
    enum CheckResult: Sendable, Equatable {
        case unavailable
        case upToDate(version: String)
        case updateAvailable(installedVersion: String, latestVersion: String)
    }

    enum UpdaterError: LocalizedError, Sendable, Equatable {
        case homebrewUnavailable
        case couldNotLaunch
        case commandFailed(command: String, status: Int32)
        case invalidResponse
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .homebrewUnavailable:
                "Homebrew is not available in its standard installation location."
            case .couldNotLaunch:
                "Homebrew could not be started."
            case .commandFailed(let command, let status):
                "Homebrew \(command) failed with status \(status)."
            case .invalidResponse:
                "Homebrew returned update information Tachyon could not read."
            case .outputTooLarge:
                "Homebrew returned more update information than Tachyon accepts."
            }
        }
    }

    typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ captureOutput: Bool,
        _ timeout: TimeInterval
    ) throws -> Data

    private static let cask = "gonzih/tap/tachyon"
    private static let maximumInfoBytes = 1024 * 1024
    private static let standardBrewPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private let brewPath: String?
    private let runCommand: CommandRunner

    init() {
        brewPath = Self.standardBrewPaths.first(where: FileManager.default.isExecutableFile(atPath:))
        runCommand = Self.execute
    }

    init(brewPath: String?, runCommand: @escaping CommandRunner) {
        self.brewPath = brewPath
        self.runCommand = runCommand
    }

    func check() async throws -> CheckResult {
        guard let brewPath else { return .unavailable }
        let runCommand = self.runCommand

        return try await Task.detached(priority: .utility) {
            _ = try runCommand(
                brewPath,
                ["update-if-needed"],
                ["HOMEBREW_AUTO_UPDATE_SECS": "0"],
                false,
                300
            )
            let data = try runCommand(
                brewPath,
                ["info", "--json=v2", "--cask", Self.cask],
                [:],
                true,
                120
            )
            return try Self.decodeCheckResult(data)
        }.value
    }

    func update() async throws {
        guard let brewPath else { throw UpdaterError.homebrewUnavailable }
        let runCommand = self.runCommand

        _ = try await Task.detached(priority: .utility) {
            try runCommand(
                brewPath,
                ["upgrade", "--cask", Self.cask],
                [:],
                false,
                600
            )
        }.value
    }

    private static func decodeCheckResult(_ data: Data) throws -> CheckResult {
        guard data.count <= maximumInfoBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let cask = casks.first(where: isTachyonCask)
        else { throw UpdaterError.invalidResponse }

        guard let installedVersion = versionString(cask["installed"]) else {
            return .unavailable
        }
        guard let latestVersion = versionString(cask["version"]),
              let outdated = cask["outdated"] as? Bool
        else { throw UpdaterError.invalidResponse }

        if outdated {
            return .updateAvailable(
                installedVersion: installedVersion,
                latestVersion: latestVersion
            )
        }
        return .upToDate(version: installedVersion)
    }

    private static func isTachyonCask(_ value: [String: Any]) -> Bool {
        value["full_token"] as? String == cask
    }

    private static func versionString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let strings = value as? [String] {
            return strings.last(where: { !$0.isEmpty })
        }
        return nil
    }

    private static func execute(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ captureOutput: Bool,
        _ timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }

        let pipe = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UpdaterError.couldNotLaunch
        }

        let watchdog = scheduleWatchdog(for: process, timeout: timeout)
        defer { watchdog.cancel() }

        let data: Data
        do {
            data = try pipe.map { try readBounded($0.fileHandleForReading) } ?? Data()
        } catch {
            terminate(process)
            process.waitUntilExit()
            throw error
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.commandFailed(
                command: arguments.first ?? "command",
                status: process.terminationStatus
            )
        }
        return data
    }

    private static func scheduleWatchdog(
        for process: Process,
        timeout: TimeInterval
    ) -> DispatchWorkItem {
        let boundedTimeout = timeout.isFinite ? min(max(1, timeout), 600) : 120
        let watchdog = DispatchWorkItem { terminate(process) }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + boundedTimeout,
            execute: watchdog
        )
        return watchdog
    }

    private static func readBounded(_ handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(64 * 1024)

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumInfoBytes - data.count else {
                throw UpdaterError.outputTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    private static func terminate(_ process: Process) {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
