import XCTest
@testable import Tachyon

/// The process test uses a synthetic executable; it never launches an installed
/// Codex binary and never reads the user's Codex home or credentials.
final class CodexAppServerProbeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-codex-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testAppServerDecoderUsesWorstWindowAndLatestDailyActivity() throws {
        let rateLimits = Data("""
        {
          "id": 3,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "planType": "self_serve_business_usage_based",
              "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1893456000},
              "secondary": {"usedPercent": 71, "windowDurationMins": 10080, "resetsAt": 1893456000}
            },
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "planType": "self_serve_business_usage_based",
                "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1893456000},
                "secondary": {"usedPercent": 71, "windowDurationMins": 10080, "resetsAt": 1893456000}
              },
              "untouched": {
                "limitName": "Untouched",
                "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1893456000}
              },
              "busy": {
                "limitName": "Busy",
                "primary": {"usedPercent": 86, "windowDurationMins": 300, "resetsAt": 1893456000}
              }
            },
            "rateLimitResetCredits": {"availableCount": 2, "credits": null}
          }
        }
        """.utf8)
        let usage = Data("""
        {
          "id": 4,
          "result": {
            "dailyUsageBuckets": [
              {"startDate": "2026-08-28", "tokens": 1200},
              {"startDate": "2026-08-30", "tokens": 3400}
            ]
          }
        }
        """.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try XCTUnwrap(CodexAppServerProbe.decodeSnapshot(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            planType: nil,
            asOf: now))
        XCTAssertEqual(snapshot.primary.label, "Busy · Current session")
        XCTAssertEqual(snapshot.primary.percentUsed, 86)
        XCTAssertEqual(snapshot.detail, "Business")
        XCTAssertEqual(snapshot.asOf, now)
        XCTAssertFalse(snapshot.windows.contains { $0.label.contains("Untouched") })
        XCTAssertEqual(snapshot.windows.first { $0.label == "Full resets" }?.count, 2)
        XCTAssertEqual(snapshot.windows.first { $0.label == "2026-08-30" }?.count, 3400)
    }

    func testExternalAuthProbeIsIsolatedAndRejectsRefresh() async throws {
        let executable = try makeExecutable(named: "fake-codex", contents: """
        #!/bin/sh
        set -eu
        [ "$(stat -f %Lp "$CODEX_HOME")" = "700" ] || exit 20
        [ "$HOME" = "$CODEX_HOME" ] || exit 20
        [ "$TMPDIR" = "$CODEX_HOME" ] || exit 20
        [ ! -e "$CODEX_HOME/auth.json" ] || exit 21
        [ "$CODEX_CA_CERTIFICATE" = "/synthetic/ca.pem" ] || exit 21
        case " $* " in *" analytics.enabled=false "*) ;; *) exit 22 ;; esac

        IFS= read -r initialize
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 23 ;; esac
        printf '%s\n' '{"id":1,"result":{"userAgent":"synthetic","codexHome":"/synthetic","platformFamily":"unix","platformOs":"macos"}}'

        IFS= read -r initialized
        case "$initialized" in *'"method":"initialized"'*) ;; *) exit 24 ;; esac
        IFS= read -r login
        case "$login" in *'"type":"chatgptAuthTokens"'*) ;; *) exit 25 ;; esac
        case "$login" in *'"refreshToken"'*) exit 26 ;; esac
        printf '%s\n' '{"method":"account/updated","params":{"authMode":"chatgptAuthTokens","planType":"pro"}}'
        printf '%s\n' '{"id":2,"result":{"type":"chatgptAuthTokens"}}'

        IFS= read -r rate_request
        case "$rate_request" in *'"id":3'*) ;; *) exit 27 ;; esac
        case "$rate_request" in *'account'*'rateLimits'*'read'*) ;; *) exit 27 ;; esac
        IFS= read -r usage_request
        case "$usage_request" in *'"id":4'*) ;; *) exit 28 ;; esac
        case "$usage_request" in *'account'*'usage'*'read'*) ;; *) exit 28 ;; esac

        printf '%s\n' '{"id":99,"method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized"}}'
        IFS= read -r refresh_rejection
        case "$refresh_rejection" in *'"id":99'*) ;; *) exit 29 ;; esac
        case "$refresh_rejection" in *'"error"'*) ;; *) exit 30 ;; esac
        case "$refresh_rejection" in *'never refreshes harness credentials'*) ;; *) exit 31 ;; esac

        printf '%s\n' '{"id":4,"result":{"dailyUsageBuckets":[{"startDate":"2026-08-30","tokens":4321}]}}'
        printf '%s\n' '{"id":3,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":44,"windowDurationMins":300,"resetsAt":1893456000},"secondary":null},"rateLimitResetCredits":null}}'
        """)

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_CA_CERTIFICATE"] = "/synthetic/ca.pem"
        let snapshot = try await CodexAppServerProbe.fetch(
            credential: .init(
                accessToken: "synthetic-access-token",
                accountID: "synthetic-account",
                planType: "pro",
                chatGPTBaseURL: nil),
            executable: executable,
            timeout: 5,
            environment: environment)
        XCTAssertEqual(snapshot.primary.percentUsed, 44)
        XCTAssertEqual(snapshot.primary.windowSeconds, 18000)
        XCTAssertEqual(snapshot.detail, "Pro")
        XCTAssertEqual(snapshot.windows.first { $0.label == "2026-08-30" }?.count, 4321)
    }

    func testDesktopResolverPrefersBundleIdentifierThenKnownApplicationPaths() throws {
        let bundleApplication = temporaryDirectory.appendingPathComponent(
            "Bundle Lookup.app",
            isDirectory: true)
        let bundleExecutable = try makeBundledExecutable(in: bundleApplication)
        let systemApplications = temporaryDirectory.appendingPathComponent(
            "System Applications",
            isDirectory: true)
        let userApplications = temporaryDirectory.appendingPathComponent(
            "User Applications",
            isDirectory: true)
        let systemExecutable = try makeBundledExecutable(
            in: systemApplications.appendingPathComponent("ChatGPT.app", isDirectory: true))
        let userExecutable = try makeBundledExecutable(
            in: userApplications.appendingPathComponent("Codex.app", isDirectory: true))

        XCTAssertEqual(CodexAppServerProbe.desktopExecutableURL(
            bundleIdentifierApplicationURL: bundleApplication,
            systemApplicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications),
            bundleExecutable.resolvingSymlinksInPath())
        XCTAssertEqual(CodexAppServerProbe.desktopExecutableURL(
            bundleIdentifierApplicationURL: nil,
            systemApplicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications),
            systemExecutable.resolvingSymlinksInPath())

        try FileManager.default.removeItem(
            at: systemApplications.appendingPathComponent("ChatGPT.app", isDirectory: true))
        XCTAssertEqual(CodexAppServerProbe.desktopExecutableURL(
            bundleIdentifierApplicationURL: nil,
            systemApplicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications),
            userExecutable.resolvingSymlinksInPath())
    }

    func testCLIResolverUsesPathAndHomebrewFallbacksWithoutDesktopBundle() throws {
        let pathDirectory = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: false)
        let pathExecutable = pathDirectory.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: pathExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: pathExecutable.path)
        let fallback = try makeExecutable(named: "fallback-codex", contents: "#!/bin/sh\nexit 0\n")

        XCTAssertEqual(CodexAppServerProbe.cliExecutableURL(
            environment: ["PATH": pathDirectory.path],
            fallbackExecutableURLs: [fallback]),
            pathExecutable.resolvingSymlinksInPath())
        XCTAssertEqual(CodexAppServerProbe.cliExecutableURL(
            environment: ["PATH": ""],
            fallbackExecutableURLs: [fallback]),
            fallback.resolvingSymlinksInPath())
    }

    func testProbeTimeoutIsBounded() async throws {
        let executable = try makeExecutable(named: "stalled-codex", contents: """
        #!/bin/sh
        IFS= read -r first
        IFS= read -r second
        """)
        let started = Date()
        do {
            _ = try await CodexAppServerProbe.fetch(
                credential: .init(
                    accessToken: "synthetic-access-token",
                    accountID: "synthetic-account",
                    planType: nil,
                    chatGPTBaseURL: nil),
                executable: executable,
                timeout: 0.1)
            XCTFail("expected timeout")
        } catch let error as CodexAppServerProbe.ProbeError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testProbeInputWriteUsesSameDeadline() async throws {
        let executable = try makeExecutable(named: "nonreading-codex", contents: """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        exec /usr/bin/tail -f /dev/null
        """)
        let started = Date()
        do {
            _ = try await CodexAppServerProbe.fetch(
                credential: .init(
                    accessToken: String(repeating: "x", count: 400_000),
                    accountID: "synthetic-account",
                    planType: nil,
                    chatGPTBaseURL: nil),
                executable: executable,
                timeout: 0.1)
            XCTFail("expected timeout")
        } catch let error as CodexAppServerProbe.ProbeError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testProbeRejectsOversizedJSONLine() async throws {
        let executable = try makeExecutable(named: "oversized-codex", contents: """
        #!/bin/sh
        IFS= read -r first
        /bin/dd if=/dev/zero bs=1048576 count=3 2>/dev/null | /usr/bin/tr '\\000' x
        """)
        do {
            _ = try await CodexAppServerProbe.fetch(
                credential: .init(
                    accessToken: "synthetic-access-token",
                    accountID: "synthetic-account",
                    planType: nil,
                    chatGPTBaseURL: nil),
                executable: executable,
                timeout: 5)
            XCTFail("expected output limit")
        } catch let error as CodexAppServerProbe.ProbeError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testPlanFormattingHandlesKnownAndUnknownValues() {
        XCTAssertEqual(CodexAppServerProbe.formatPlan("edu_plus"), "Edu Plus")
        XCTAssertEqual(
            CodexAppServerProbe.formatPlan("self_serve_business_prolite"),
            "Business Pro Lite")
        XCTAssertEqual(CodexAppServerProbe.formatPlan("future_super_tier"), "Future Super Tier")
        XCTAssertNil(CodexAppServerProbe.formatPlan("  "))
    }

    private func makeExecutable(named name: String, contents: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
        return url
    }

    private func makeBundledExecutable(in application: URL) throws -> URL {
        let resources = application.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = resources.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path)
        return executable
    }
}
