import XCTest
@testable import Tachyon

/// Codex fixtures contain only synthetic values and intentionally exercise
/// schema variants seen across the direct endpoint and rollout JSONL stream.
final class CodexProviderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-codex-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDirectDecoderAcceptsSecondaryOnlyAndFormatsPlan() throws {
        let fixture = """
        {
          "plan_type": "self_serve_business_usage_based",
          "rate_limit": {
            "primary_window": null,
            "secondary_window": {
              "used_percent": 73,
              "limit_window_seconds": 604800,
              "reset_at": 1893456000
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(
            CodexProvider.decodeUsage(Data(fixture.utf8), planType: nil))
        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(snapshot.primary.percentUsed, 73)
        XCTAssertEqual(snapshot.primary.windowSeconds, 604800)
        XCTAssertEqual(snapshot.detail, "Business plan")
    }

    func testDirectDecoderFeedsGenericPaceProjection() throws {
        let fixture = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 60,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 9000
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(
            CodexProvider.decodeUsage(Data(fixture.utf8), planType: nil))
        XCTAssertEqual(
            PaceFormat.caption(for: snapshot.primary),
            "At this pace, limit before reset")
        XCTAssertTrue(snapshot.primary.isPaceHot)
    }

    func testDirectWeeklyWindowShowsEarlyRunwayWarningWithoutVisualEscalation() throws {
        // Mirrors the live Codex CLI case: 13% used roughly four hours into a
        // weekly window. The caption must not disappear just because the
        // stable color/pulse sample has not reached 10% elapsed yet.
        let fixture = """
        {
          "rate_limit": {
            "secondary_window": {
              "used_percent": 13,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 589200
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(
            CodexProvider.decodeUsage(Data(fixture.utf8), planType: "pro"))
        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(snapshot.primary.windowSeconds, 604800)
        XCTAssertEqual(
            PaceFormat.caption(for: snapshot.primary),
            "At this pace, limit before reset")
        XCTAssertFalse(snapshot.primary.isPaceHot)
        XCTAssertEqual(snapshot.primary.bandPercent, 13)
    }

    func testPathologicalWindowNumbersDegradeWithoutTrapping() {
        let fixture = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 1e100,
              "reset_after_seconds": 1e100
            }
          }
        }
        """
        let snapshot = CodexProvider.decodeUsage(Data(fixture.utf8), planType: nil)
        XCTAssertEqual(snapshot?.primary.label, "Current session")
        XCTAssertNil(snapshot?.primary.windowSeconds)
        XCTAssertNil(snapshot?.primary.resetsAt)
    }

    func testRequestHeadersOmitBlankAccountAndContentType() {
        let withoutAccount = CodexProvider.requestHeaders(
            accessToken: "synthetic-access-token",
            accountID: "  ")
        XCTAssertEqual(withoutAccount, [
            "Authorization": "Bearer synthetic-access-token",
        ])

        let withAccount = CodexProvider.requestHeaders(
            accessToken: "synthetic-access-token",
            accountID: "  synthetic-account  ")
        XCTAssertEqual(withAccount["ChatGPT-Account-Id"], "synthetic-account")
        XCTAssertNil(withAccount["Content-Type"])
        XCTAssertNil(CodexProvider.requestHeaders(
            accessToken: "synthetic-access-token",
            accountID: "synthetic\naccount"
        )["ChatGPT-Account-Id"])
    }

    func testEndpointSelectionMatchesCodexPathStyle() {
        XCTAssertEqual(
            CodexProvider.usageURL(baseURL: nil).absoluteString,
            "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(
            CodexProvider.usageURL(baseURL: "https://chatgpt.com/").absoluteString,
            "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(
            CodexProvider.usageURL(baseURL: "https://synthetic.invalid/root/").absoluteString,
            "https://synthetic.invalid/root/api/codex/usage")
    }

    func testEndpointValidationRejectsCredentialLeakProneBases() {
        let official = "https://chatgpt.com/backend-api/wham/usage"
        for rejected in [
            "http://synthetic.invalid",
            "https://user:password@synthetic.invalid",
            "https://synthetic.invalid/root?route=usage",
            "https://synthetic.invalid/root#usage",
        ] {
            XCTAssertNil(CodexProvider.validatedBaseURL(rejected), rejected)
            XCTAssertEqual(CodexProvider.usageURL(baseURL: rejected).absoluteString, official)
        }
    }

    func testEndpointValidationAllowsExplicitLoopbackHTTP() {
        let loopbacks = [
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
        ]
        for base in loopbacks {
            XCTAssertNotNil(CodexProvider.validatedBaseURL(base), base)
            XCTAssertTrue(
                CodexProvider.usageURL(baseURL: base).absoluteString.hasSuffix("/api/codex/usage"),
                base
            )
        }
    }

    func testChatGPTBaseURLParserReadsOnlyQuotedTopLevelValue() {
        let config = """
        # chatgpt_base_url = "https://ignored.invalid"
        model = "synthetic"
        chatgpt_base_url = "https://synthetic.invalid/backend-api/"
        """
        XCTAssertEqual(
            CodexProvider.chatGPTBaseURL(configContents: config),
            "https://synthetic.invalid/backend-api")
        XCTAssertNil(CodexProvider.chatGPTBaseURL(
            configContents: "chatgpt_base_url = https://unquoted.invalid"))
        XCTAssertNil(CodexProvider.chatGPTBaseURL(
            configContents: "chatgpt_base_url = 'https://synthetic.invalid/#literal' # comment"))
        XCTAssertEqual(CodexProvider.chatGPTBaseURL(
            configContents: "chatgpt_base_url = 'https://synthetic.invalid/path%23literal' # comment"),
            "https://synthetic.invalid/path%23literal")
    }

    func testRolloutChoosesNewestEventAcrossFilesAndWorstWindow() throws {
        let sessions = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let olderEvent = day.appendingPathComponent("rollout-older.jsonl")
        try rolloutLine(
            timestamp: "2026-08-30T10:00:00Z",
            primaryPercent: 96,
            secondaryPercent: nil,
            plan: "pro")
            .write(to: olderEvent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: olderEvent.path)

        let newerEvent = day.appendingPathComponent("rollout-newer.jsonl")
        try rolloutLine(
            timestamp: "2026-08-30T11:00:00Z",
            primaryPercent: 20,
            secondaryPercent: 84,
            plan: "self_serve_business_prolite")
            .write(to: newerEvent, atomically: true, encoding: .utf8)
        // File mtime intentionally disagrees with the event timestamp.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: newerEvent.path)

        let snapshot = try XCTUnwrap(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: sessions.path))
        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(snapshot.primary.percentUsed, 84)
        XCTAssertEqual(snapshot.primary.windowSeconds, 604800)
        XCTAssertEqual(snapshot.windows.first { $0.label == "Current session" }?.windowSeconds, 18000)
        XCTAssertEqual(snapshot.detail, "Business Pro Lite plan")
        XCTAssertEqual(
            snapshot.asOf,
            ISO8601DateFormatter().date(from: "2026-08-30T11:00:00Z"))

        let asOf = snapshot.asOf
        XCTAssertTrue(CodexProvider.rolloutIsEligible(
            snapshot,
            authenticated: false,
            now: asOf.addingTimeInterval(120)
        ))
        XCTAssertFalse(CodexProvider.rolloutIsEligible(
            snapshot,
            authenticated: true,
            now: asOf.addingTimeInterval(120)
        ), "rollout history has no account binding")
        XCTAssertFalse(CodexProvider.rolloutIsEligible(
            snapshot,
            authenticated: false,
            now: asOf.addingTimeInterval(180)
        ))
        XCTAssertTrue(CodexProvider.rolloutIsEligible(
            snapshot,
            authenticated: false,
            now: asOf.addingTimeInterval(-60)
        ))
        XCTAssertFalse(CodexProvider.rolloutIsEligible(
            snapshot,
            authenticated: false,
            now: asOf.addingTimeInterval(-60.001)
        ), "materially future records must be rejected")
    }

    func testRolloutSurfacesKeepDesktopAndCLISourcesSeparate() throws {
        let sessions = temporaryDirectory.appendingPathComponent(
            "surface-sessions",
            isDirectory: true)
        let day = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let desktop = day.appendingPathComponent("rollout-desktop.jsonl")
        try rolloutContents(
            originator: "Codex Desktop",
            timestamp: "2026-08-30T11:00:00Z",
            primaryPercent: 81)
            .write(to: desktop, atomically: true, encoding: .utf8)

        let cli = day.appendingPathComponent("rollout-cli.jsonl")
        try rolloutContents(
            originator: "codex_cli_rs",
            timestamp: "2026-08-30T12:00:00Z",
            primaryPercent: 42)
            .write(to: cli, atomically: true, encoding: .utf8)

        XCTAssertEqual(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: sessions.path,
            surface: .desktop)?.primary.percentUsed, 81)
        XCTAssertEqual(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: sessions.path,
            surface: .cli)?.primary.percentUsed, 42)
    }

    func testRolloutFreshnessFilterSkipsFutureEventBeforeChoosingNewest() throws {
        let sessions = temporaryDirectory.appendingPathComponent(
            "clock-skew-sessions",
            isDirectory: true)
        let day = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        let contents = """
        {"type":"session_meta","payload":{"originator":"Codex Desktop"}}
        \(rolloutLine(
            timestamp: formatter.string(from: now.addingTimeInterval(-30)),
            primaryPercent: 33,
            secondaryPercent: nil,
            plan: "pro"))
        \(rolloutLine(
            timestamp: formatter.string(from: now.addingTimeInterval(61)),
            primaryPercent: 99,
            secondaryPercent: nil,
            plan: "pro"))
        """
        try contents.write(
            to: day.appendingPathComponent("rollout-clock-skew.jsonl"),
            atomically: true,
            encoding: .utf8)

        let snapshot = CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: sessions.path,
            surface: .desktop,
            eligibleAt: now)
        XCTAssertEqual(snapshot?.primary.percentUsed, 33)
    }

    func testDesktopOriginatorIsExactAndMetadataReadIsBounded() throws {
        let wrongCase = temporaryDirectory.appendingPathComponent("rollout-wrong-case.jsonl")
        try rolloutContents(
            originator: "codex desktop",
            timestamp: "2026-08-30T11:00:00Z",
            primaryPercent: 20)
            .write(to: wrongCase, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexProvider.rolloutOriginator(path: wrongCase.path), "codex desktop")

        let beyondPrefix = temporaryDirectory.appendingPathComponent("rollout-beyond-prefix.jsonl")
        let contents = String(repeating: " ", count: 70 * 1024)
            + "\n"
            + rolloutContents(
                originator: "Codex Desktop",
                timestamp: "2026-08-30T11:00:00Z",
                primaryPercent: 20)
        try contents.write(to: beyondPrefix, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexProvider.rolloutOriginator(path: beyondPrefix.path))

        let sessions = temporaryDirectory.appendingPathComponent(
            "exact-originator-sessions/2026/08/30",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: wrongCase,
            to: sessions.appendingPathComponent("rollout-wrong-case.jsonl"))
        XCTAssertNil(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: temporaryDirectory
                .appendingPathComponent("exact-originator-sessions").path,
            surface: .desktop))
    }

    func testSurfaceFilteringPrecedesFileLimitInBothDirections() throws {
        let cliTarget = temporaryDirectory.appendingPathComponent("cli-target", isDirectory: true)
        try writeCompetingRollouts(
            sessions: cliTarget,
            newerOriginator: "Codex Desktop",
            olderOriginator: "codex_cli_rs",
            olderPercent: 33)
        XCTAssertEqual(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: cliTarget.path,
            surface: .cli)?.primary.percentUsed, 33)

        let desktopTarget = temporaryDirectory.appendingPathComponent(
            "desktop-target",
            isDirectory: true)
        try writeCompetingRollouts(
            sessions: desktopTarget,
            newerOriginator: "codex_cli_rs",
            olderOriginator: "Codex Desktop",
            olderPercent: 77)
        XCTAssertEqual(CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: desktopTarget.path,
            surface: .desktop)?.primary.percentUsed, 77)
    }

    func testCredentialFingerprintSeparatesCodexAccountsAndTokenRotations() {
        let first = CodexProvider.credentialFingerprint(
            accessToken: "synthetic-token-a",
            accountID: "synthetic-account-a"
        )
        let second = CodexProvider.credentialFingerprint(
            accessToken: "synthetic-token-b",
            accountID: "synthetic-account-b"
        )
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(CodexProvider.credentialFingerprint(
            accessToken: "synthetic-token-without-account-id",
            accountID: nil
        ))
        XCTAssertNil(CodexProvider.credentialFingerprint(accessToken: "", accountID: nil))
    }

    func testRolloutDayTraversalContinuesPastMinimumUntilEnoughCandidates() throws {
        let sessions = temporaryDirectory.appendingPathComponent("sparse-sessions", isDirectory: true)
        let newestDay = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        let olderDay = sessions.appendingPathComponent("2026/08/29", isDirectory: true)
        try FileManager.default.createDirectory(at: newestDay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderDay, withIntermediateDirectories: true)
        try "{}\n".write(
            to: olderDay.appendingPathComponent("rollout-synthetic.jsonl"),
            atomically: true,
            encoding: .utf8)

        let files = CodexProvider.newestRolloutFiles(
            limit: 1,
            sessionsPath: sessions.path,
            minimumDayDirectories: 1,
            hardMaximumDayDirectories: 2)

        XCTAssertEqual(files.map { URL(fileURLWithPath: $0).lastPathComponent }, [
            "rollout-synthetic.jsonl",
        ])
    }

    func testRolloutDayTraversalRetainsIndependentHardSafetyCap() throws {
        let sessions = temporaryDirectory.appendingPathComponent("bounded-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions.appendingPathComponent("2026/08/30", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessions.appendingPathComponent("2026/08/29", isDirectory: true),
            withIntermediateDirectories: true)
        let olderDay = sessions.appendingPathComponent("2026/08/28", isDirectory: true)
        try FileManager.default.createDirectory(at: olderDay, withIntermediateDirectories: true)
        try "{}\n".write(
            to: olderDay.appendingPathComponent("rollout-synthetic.jsonl"),
            atomically: true,
            encoding: .utf8)

        XCTAssertTrue(CodexProvider.newestRolloutFiles(
            limit: 1,
            sessionsPath: sessions.path,
            minimumDayDirectories: 1,
            hardMaximumDayDirectories: 2).isEmpty)
        XCTAssertEqual(CodexProvider.newestRolloutFiles(
            limit: 1,
            sessionsPath: sessions.path,
            minimumDayDirectories: 1,
            hardMaximumDayDirectories: 3).count, 1)
        XCTAssertTrue(CodexProvider.newestRolloutFiles(
            limit: 0,
            sessionsPath: sessions.path,
            minimumDayDirectories: 1,
            hardMaximumDayDirectories: 3).isEmpty)
    }

    private func rolloutLine(
        timestamp: String,
        primaryPercent: Int,
        secondaryPercent: Int?,
        plan: String
    ) -> String {
        let secondary = secondaryPercent.map {
            """
            {"used_percent":\($0),"window_minutes":10080,"resets_at":1893456000}
            """
        } ?? "null"
        return """
        {"timestamp":"\(timestamp)","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(primaryPercent),"window_minutes":300,"resets_at":1893456000},"secondary":\(secondary),"plan_type":"\(plan)"}}}
        """
    }

    private func rolloutContents(
        originator: String,
        timestamp: String,
        primaryPercent: Int
    ) -> String {
        """
        {"type":"session_meta","payload":{"originator":"\(originator)"}}
        \(rolloutLine(
            timestamp: timestamp,
            primaryPercent: primaryPercent,
            secondaryPercent: nil,
            plan: "pro"))
        """
    }

    private func writeCompetingRollouts(
        sessions: URL,
        newerOriginator: String,
        olderOriginator: String,
        olderPercent: Int
    ) throws {
        let day = sessions.appendingPathComponent("2026/08/30", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for index in 0..<6 {
            let file = day.appendingPathComponent("rollout-newer-\(index).jsonl")
            try rolloutContents(
                originator: newerOriginator,
                timestamp: "2026-08-30T12:00:0\(index)Z",
                primaryPercent: 90)
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 200 + Double(index))],
                ofItemAtPath: file.path)
        }
        let older = day.appendingPathComponent("rollout-older-target.jsonl")
        try rolloutContents(
            originator: olderOriginator,
            timestamp: "2026-08-30T10:00:00Z",
            primaryPercent: olderPercent)
            .write(to: older, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path)
    }
}
