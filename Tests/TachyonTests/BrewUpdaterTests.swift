import Foundation
import XCTest
@testable import Tachyon

private struct BrewCommandCall: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let capturesOutput: Bool
    let timeout: TimeInterval
}

private final class BrewCommandStub: @unchecked Sendable {
    private let lock = NSLock()
    private let infoData: Data
    private let failingCommand: String?
    private var recordedCalls: [BrewCommandCall] = []

    init(infoJSON: String = "{}", failingCommand: String? = nil) {
        infoData = Data(infoJSON.utf8)
        self.failingCommand = failingCommand
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        captureOutput: Bool,
        timeout: TimeInterval
    ) throws -> Data {
        lock.withLock {
            recordedCalls.append(BrewCommandCall(
                executable: executable,
                arguments: arguments,
                environment: environment,
                capturesOutput: captureOutput,
                timeout: timeout
            ))
        }

        if arguments.first == failingCommand {
            throw BrewUpdater.UpdaterError.commandFailed(
                command: arguments.first ?? "command",
                status: 1
            )
        }
        return arguments.first == "info" ? infoData : Data()
    }

    var calls: [BrewCommandCall] {
        lock.withLock { recordedCalls }
    }
}

final class BrewUpdaterTests: XCTestCase {
    private let brewPath = "/opt/homebrew/bin/brew"

    func testCheckRefreshesMetadataThenReadsCurrentCask() async throws {
        let stub = BrewCommandStub(infoJSON: Self.infoJSON(
            installed: #""1.8""#,
            latest: "1.8",
            outdated: false
        ))
        let updater = makeUpdater(stub)

        let result = try await updater.check()

        XCTAssertEqual(result, .upToDate(version: "1.8"))
        XCTAssertEqual(stub.calls, [
            BrewCommandCall(
                executable: brewPath,
                arguments: ["update-if-needed"],
                environment: ["HOMEBREW_AUTO_UPDATE_SECS": "0"],
                capturesOutput: false,
                timeout: 300
            ),
            BrewCommandCall(
                executable: brewPath,
                arguments: ["info", "--json=v2", "--cask", "gonzih/tap/tachyon"],
                environment: [:],
                capturesOutput: true,
                timeout: 120
            ),
        ])
    }

    func testCheckReportsAvailableVersionAndAcceptsInstalledVersionArray() async throws {
        let stub = BrewCommandStub(infoJSON: Self.infoJSON(
            installed: #"["1.8"]"#,
            latest: "1.9",
            outdated: true
        ))

        let result = try await makeUpdater(stub).check()

        XCTAssertEqual(result, .updateAvailable(
            installedVersion: "1.8",
            latestVersion: "1.9"
        ))
    }

    func testCheckReportsUnavailableWhenCaskHasNoReceipt() async throws {
        let stub = BrewCommandStub(infoJSON: Self.infoJSON(
            installed: "null",
            latest: "1.9",
            outdated: false
        ))

        let result = try await makeUpdater(stub).check()

        XCTAssertEqual(result, .unavailable)
    }

    func testCheckFailsClosedForMalformedMetadata() async {
        let stub = BrewCommandStub(infoJSON: #"{"casks":[]}"#)

        do {
            _ = try await makeUpdater(stub).check()
            XCTFail("Malformed metadata should fail")
        } catch {
            XCTAssertEqual(error as? BrewUpdater.UpdaterError, .invalidResponse)
        }
    }

    func testCheckStopsWhenMetadataRefreshFails() async {
        let stub = BrewCommandStub(failingCommand: "update-if-needed")

        do {
            _ = try await makeUpdater(stub).check()
            XCTFail("A failed metadata refresh should fail the check")
        } catch {
            XCTAssertEqual(
                error as? BrewUpdater.UpdaterError,
                .commandFailed(command: "update-if-needed", status: 1)
            )
        }
        XCTAssertEqual(stub.calls.map(\.arguments), [["update-if-needed"]])
    }

    func testMissingHomebrewDoesNoWork() async throws {
        let stub = BrewCommandStub()
        let updater = BrewUpdater(brewPath: nil, runCommand: stub.run)

        let result = try await updater.check()
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(stub.calls.isEmpty)

        do {
            try await updater.update()
            XCTFail("An update cannot start without Homebrew")
        } catch {
            XCTAssertEqual(error as? BrewUpdater.UpdaterError, .homebrewUnavailable)
        }
    }

    func testUpdateRunsOnlyTheAgreedCaskUpgrade() async throws {
        let stub = BrewCommandStub()

        try await makeUpdater(stub).update()

        XCTAssertEqual(stub.calls, [
            BrewCommandCall(
                executable: brewPath,
                arguments: ["upgrade", "--cask", "gonzih/tap/tachyon"],
                environment: [:],
                capturesOutput: false,
                timeout: 600
            ),
        ])
    }

    private func makeUpdater(_ stub: BrewCommandStub) -> BrewUpdater {
        BrewUpdater(brewPath: brewPath, runCommand: stub.run)
    }

    private static func infoJSON(
        installed: String,
        latest: String,
        outdated: Bool
    ) -> String {
        """
        {
          "casks": [{
            "token": "tachyon",
            "full_token": "gonzih/tap/tachyon",
            "version": "\(latest)",
            "installed": \(installed),
            "outdated": \(outdated)
          }]
        }
        """
    }
}
