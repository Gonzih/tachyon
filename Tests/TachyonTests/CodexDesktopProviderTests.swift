import XCTest
@testable import Tachyon

final class CodexDesktopProviderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-codex-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFreshDesktopRolloutIsReadyCurrentAndIdentityless() async throws {
        let sessions = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRollout(
            sessions: sessions,
            originator: "Codex Desktop",
            timestamp: asOf,
            percent: 67)
        let provider = CodexDesktopProvider(
            sessionsPath: sessions.path,
            executableResolver: { nil },
            now: { asOf.addingTimeInterval(30) })

        let presence = await provider.detect()
        XCTAssertEqual(presence, .ready)
        let reading = await provider.reading()
        XCTAssertNil(reading.accountFingerprint)
        guard case .ok(let snapshot) = reading.state else {
            return XCTFail("expected a current local rollout reading")
        }
        XCTAssertEqual(snapshot.primary.percentUsed, 67)
        XCTAssertEqual(snapshot.asOf, asOf)
        XCTAssertEqual(snapshot.primary.windowSeconds, 18_000)
        XCTAssertEqual(snapshot.primary.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testDesktopRolloutBecomesStaleAfterOnePollInterval() async throws {
        let sessions = temporaryDirectory.appendingPathComponent(
            "stale-sessions",
            isDirectory: true)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRollout(
            sessions: sessions,
            originator: "Codex Desktop",
            timestamp: asOf,
            percent: 67)
        let provider = CodexDesktopProvider(
            sessionsPath: sessions.path,
            executableResolver: { nil },
            now: { asOf.addingTimeInterval(60) })

        let reading = await provider.reading()
        guard case .stale(let snapshot, let staleAsOf) = reading.state else {
            return XCTFail("expected stale history after one poll interval")
        }
        XCTAssertEqual(snapshot.primary.percentUsed, 67)
        XCTAssertEqual(staleAsOf, asOf)
    }

    func testDesktopRolloutExpiresAtThreePollIntervals() async throws {
        let sessions = temporaryDirectory.appendingPathComponent(
            "expired-sessions",
            isDirectory: true)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRollout(
            sessions: sessions,
            originator: "Codex Desktop",
            timestamp: asOf,
            percent: 67)
        let provider = CodexDesktopProvider(
            sessionsPath: sessions.path,
            executableResolver: { URL(fileURLWithPath: "/synthetic/Codex.app/codex") },
            now: { asOf.addingTimeInterval(180) })

        let presence = await provider.detect()
        let state = await provider.snapshot()
        XCTAssertEqual(presence, .notSignedIn("Run a turn in Codex Desktop"))
        XCTAssertEqual(state, .unavailable)
    }

    func testInstalledDesktopWithoutEligibleRolloutShowsGuidance() async throws {
        let sessions = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRollout(
            sessions: sessions,
            originator: "codex desktop",
            timestamp: now,
            percent: 50)
        let provider = CodexDesktopProvider(
            sessionsPath: sessions.path,
            executableResolver: { URL(fileURLWithPath: "/synthetic/Codex.app/codex") },
            now: { now })

        let presence = await provider.detect()
        XCTAssertEqual(presence, .notSignedIn("Run a turn in Codex Desktop"))
        let state = await provider.snapshot()
        XCTAssertEqual(state, .unavailable)
    }

    func testAbsentDesktopIgnoresCLIAuthAndReportsNotInstalled() async throws {
        let codexHome = temporaryDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "{\"tokens\":{\"access_token\":\"synthetic\"}}".write(
            to: codexHome.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8)
        let provider = CodexDesktopProvider(
            sessionsPath: codexHome.appendingPathComponent("sessions").path,
            executableResolver: { nil },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })

        let presence = await provider.detect()
        XCTAssertEqual(presence, .notInstalled)
        let reading = await provider.reading()
        XCTAssertEqual(reading.state, .unavailable)
        XCTAssertNil(reading.accountFingerprint)
    }

    private func writeRollout(
        sessions: URL,
        originator: String,
        timestamp: Date,
        percent: Int
    ) throws {
        let day = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let formattedTimestamp = ISO8601DateFormatter().string(from: timestamp)
        let contents = """
        {"type":"session_meta","payload":{"originator":"\(originator)"}}
        {"timestamp":"\(formattedTimestamp)","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(percent),"window_minutes":300,"resets_at":1893456000},"secondary":null,"plan_type":"pro"}}}
        """
        try contents.write(
            to: day.appendingPathComponent("rollout-synthetic.jsonl"),
            atomically: true,
            encoding: .utf8)
    }
}
