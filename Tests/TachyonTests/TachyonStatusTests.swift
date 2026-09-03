import Foundation
import XCTest
@testable import Tachyon
@testable import TachyonCLI
@testable import TachyonIPC

final class TachyonStatusTests: XCTestCase {
    @MainActor
    func testSnapshotReportsEnabledProvidersWithoutPrivateModelFields() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let current = snapshot(
            windows: [
                UsageWindow(
                    label: "Weekly",
                    percentUsed: 56,
                    resetsAt: now.addingTimeInterval(3_600),
                    windowSeconds: 7 * 86_400
                ),
                UsageWindow(label: "Current session", percentUsed: 7, resetsAt: nil)
            ],
            asOf: now,
            detail: "Pro"
        )
        let stale = snapshot(
            windows: [UsageWindow(label: "Credits", spendUSD: 34, budgetUSD: 100, resetsAt: nil)],
            asOf: now.addingTimeInterval(-60),
            detail: nil
        )

        let response = TachyonStatusSnapshot.make(
            slots: [
                slot(id: "claude", state: .ok(current)),
                slot(id: "router", state: .stale(stale, asOf: stale.asOf)),
                slot(id: "cursor", presence: .notInstalled, state: .unavailable),
                slot(id: "disabled", state: .ok(current), enabled: false),
            ],
            appVersion: "test",
            now: now
        )

        XCTAssertEqual(response.schemaVersion, 1)
        XCTAssertEqual(response.providers.map(\.id), ["claude", "router", "cursor"])
        XCTAssertEqual(response.providers[0].state, .current)
        XCTAssertEqual(response.providers[1].state, .stale)
        XCTAssertEqual(response.providers[2].presence, .notInstalled)
        XCTAssertEqual(response.providers[0].windows[0].displayValue, "56% Used")
        XCTAssertEqual(response.providers[0].windows[1].displayValue, "7% Used")
        XCTAssertEqual(response.providers[1].windows[0].displayValue, "$34 of $100")
        XCTAssertEqual(response.providers[0].detail, "Pro")

        let data = try TachyonStatusProtocol.encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertNil(providers[0]["accountFingerprint"])
        XCTAssertNil(providers[0]["credential"])
        XCTAssertNil(providers[0]["token"])
    }

    func testProtocolRoundTripsVersionedStatus() throws {
        let response = Self.sampleResponse
        let data = try TachyonStatusProtocol.encode(response)
        let decoded = try TachyonStatusProtocol.decode(TachyonStatusResponse.self, from: data)

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(TachyonStatusRequest().schemaVersion, TachyonStatusProtocol.schemaVersion)
        XCTAssertTrue(TachyonStatusRequest().isSupported)
        XCTAssertFalse(TachyonStatusRequest(schemaVersion: 99).isSupported)
    }

    @MainActor
    func testMessagePortReturnsOnlyServerSnapshot() async throws {
        let portName = "dev.gonzih.tachyon.tests.\(UUID().uuidString)"
        let response = Self.sampleResponse
        let server = TachyonStatusServer(portName: portName) { response }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        let client = TachyonStatusClient(portName: portName)
        let received = try await Task.detached {
            try client.status(timeout: 2)
        }.value

        XCTAssertEqual(received, response)
    }

    func testMissingAppPortHasActionableError() {
        let client = TachyonStatusClient(portName: "dev.gonzih.tachyon.tests.missing.\(UUID().uuidString)")

        XCTAssertThrowsError(try client.status()) { error in
            XCTAssertEqual(error as? TachyonStatusClientError, .appNotRunning)
            XCTAssertEqual(
                (error as? TachyonStatusClientError)?.errorDescription,
                "Tachyon isn’t running. Open Tachyon and try again."
            )
        }
    }

    func testCLIParserAcceptsStatusAndJSONOnly() throws {
        XCTAssertEqual(try TachyonCLIParser.parse(["status"]), .status(json: false))
        XCTAssertEqual(try TachyonCLIParser.parse(["status", "--json"]), .status(json: true))
        XCTAssertEqual(try TachyonCLIParser.parse(["--json", "status"]), .status(json: true))
        XCTAssertEqual(try TachyonCLIParser.parse(["--help"]), .help)
        XCTAssertThrowsError(try TachyonCLIParser.parse(["refresh"]))
        XCTAssertThrowsError(try TachyonCLIParser.parse(["status", "--refresh"]))
    }

    func testCLIInvocationRequiresHomebrewCommandName() {
        XCTAssertTrue(TachyonCommandLine.isCLIInvocation(arguments: ["/opt/homebrew/bin/tachyon", "status"]))
        XCTAssertFalse(TachyonCommandLine.isCLIInvocation(arguments: ["/Applications/Tachyon.app/Contents/MacOS/Tachyon"]))
        XCTAssertFalse(TachyonCommandLine.isCLIInvocation(arguments: []))
    }

    func testHumanRendererMakesCurrentStaleAndUnavailableClearWithoutANSI() {
        let response = TachyonStatusResponse(
            generatedAt: "2026-09-03T12:00:00Z",
            appVersion: "test",
            providers: [
                Self.sampleResponse.providers[0],
                TachyonProviderStatus(
                    id: "stale",
                    name: "Cursor",
                    source: nil,
                    presence: .ready,
                    state: .stale,
                    updatedAt: "2026-09-03T11:58:00Z",
                    detail: nil,
                    windows: []
                ),
                TachyonProviderStatus(
                    id: "unavailable",
                    name: "Grok Bot",
                    source: "Bot",
                    presence: .ready,
                    state: .unavailable,
                    updatedAt: nil,
                    detail: "Open Grok Bot and sign in.",
                    windows: []
                ),
            ]
        )

        let text = TachyonStatusRenderer.render(response, usesColor: false)

        XCTAssertTrue(text.contains("Tachyon test · cached 2026-09-03T12:00:00Z"))
        XCTAssertTrue(text.contains("Claude · Code  current"))
        XCTAssertTrue(text.contains("Weekly — 56% Used · Resets Thu 5:59 PM"))
        XCTAssertTrue(text.contains("Cursor  stale"))
        XCTAssertTrue(text.contains("as of 2026-09-03T11:58:00Z"))
        XCTAssertTrue(text.contains("Grok Bot · Bot  unavailable"))
        XCTAssertFalse(text.contains("\u{001B}["))
    }

    private static let sampleResponse = TachyonStatusResponse(
        generatedAt: "2026-09-03T12:00:00Z",
        appVersion: "test",
        providers: [
            TachyonProviderStatus(
                id: "claude",
                name: "Claude",
                source: "Code",
                presence: .ready,
                state: .current,
                updatedAt: "2026-09-03T12:00:00Z",
                detail: "Pro",
                windows: [
                    TachyonUsageWindow(
                        label: "Weekly",
                        percentUsed: 56,
                        spendUSD: nil,
                        budgetUSD: nil,
                        count: nil,
                        countUnit: nil,
                        resetsAt: "2026-09-04T00:00:00Z",
                        windowSeconds: 604_800,
                        displayValue: "56% Used",
                        resetText: "Resets Thu 5:59 PM"
                    )
                ]
            )
        ]
    )

    @MainActor
    private func slot(
        id: String,
        presence: ProviderPresence = .ready,
        state: ProviderState,
        enabled: Bool = true
    ) -> ProviderSlot {
        ProviderSlot(
            id: id,
            displayName: id.capitalized,
            shortName: id.capitalized,
            glyph: .claude,
            isExperimental: false,
            providerSettings: [],
            about: nil,
            category: .subscription,
            sourceLabel: "Code",
            staleIndicatorDelay: 0,
            accountFingerprint: nil,
            presence: presence,
            state: state,
            enabled: enabled,
            lastPolled: nil,
            awaitingFirstSnapshot: false
        )
    }

    private func snapshot(
        windows: [UsageWindow],
        asOf: Date,
        detail: String?
    ) -> UsageSnapshot {
        UsageSnapshot(primary: windows[0], windows: windows, asOf: asOf, detail: detail)
    }
}
