import Foundation
import XCTest
@testable import Tachyon

final class AntigravityProviderTests: XCTestCase {
    func testIdenticallyNamedWeeklyBucketsKeepTheirModelGroups() throws {
        let fixture = """
        {"command":{"data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"name":"Weekly Limit Remaining","remaining_fraction":0.93,
             "reset_time":"2030-01-04T11:25:00Z"}
          ]},
          {"name":"Claude and GPT models","buckets":[
            {"name":"Weekly Limit Remaining","remaining_fraction":1,
             "reset_time":"2030-01-04T12:20:00Z"},
            {"name":"Five Hour Limit Remaining","remaining_fraction":0.98,
             "reset_time":"2030-01-01T17:20:00Z"}
          ]}
        ]}}}
        """
        let snapshot = try XCTUnwrap(AntigravityProvider.decodeUsage(Data(fixture.utf8), asOf: Date()))
        XCTAssertEqual(snapshot.windows.map(\.label), [
            "Gemini · Weekly", "Claude / GPT · Weekly", "Claude / GPT · 5-hour",
        ])
        XCTAssertEqual(try XCTUnwrap(snapshot.primary.percentUsed), 7, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].percentUsed, 0)
        XCTAssertNotEqual(snapshot.windows[0].resetsAt, snapshot.windows[1].resetsAt)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.windowSeconds == nil },
                      "Changing labels must not infer a pace duration")
    }

    func testQuotaLabelsPreserveUnknownGroupsAndMissingNames() throws {
        let fixture = """
        {"command":{"data":{"groups":[
          {"name":"New model pool","buckets":[
            {"name":"Daily Remaining","remaining_fraction":0.5}
          ]},
          {"name":"Gemini Models","buckets":[{"remaining_fraction":1}]},
          {"buckets":[{"name":"Weekly Limit Remaining","remaining_fraction":1}]}
        ]}}}
        """
        let snapshot = try XCTUnwrap(AntigravityProvider.decodeUsage(Data(fixture.utf8), asOf: Date()))
        XCTAssertEqual(snapshot.windows.map(\.label), ["New model pool · Daily", "Gemini", "Weekly"])
    }

    func testUsageDecoderUsesProviderReportedBucketsAndResets() throws {
        let fixture = """
        {
          "command": {
            "data": {
              "groups": [
                {
                  "name": "Model quotas",
                  "buckets": [
                    {
                      "name": "Current session",
                      "window": "5h",
                      "remaining_fraction": 0.69,
                      "reset_time": "2030-01-02T03:04:05Z"
                    },
                    {
                      "name": "Weekly",
                      "window": "7d",
                      "remaining_fraction": 0.22,
                      "reset_time": "2030-01-06T03:04:05Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(AntigravityProvider.decodeUsage(
            Data(fixture.utf8), asOf: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(snapshot.primary.percentUsed ?? -1, 78, accuracy: 0.001)
        XCTAssertEqual(snapshot.primary.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(snapshot.windows[1].label, "Current session")
        XCTAssertEqual(snapshot.windows[1].percentUsed ?? -1, 31, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].windowSeconds, 5 * 60 * 60)
        XCTAssertNotNil(snapshot.primary.resetsAt)
        XCTAssertNil(snapshot.detail)
    }

    func testUsageDecoderRejectsMissingOrInvalidFractions() {
        let fixture = """
        { "command": { "data": { "groups": [{ "buckets": [
          { "name": "bad", "remaining_fraction": 1.1 },
          { "name": "missing" }
        ] }] } } }
        """

        XCTAssertNil(AntigravityProvider.decodeUsage(Data(fixture.utf8), asOf: Date()))
    }

    func testPresenceDoesNotNeedOrReadCredentials() async {
        let installed = AntigravityProvider(dependencies: .init(
            findCLI: { "/synthetic/agy" },
            isDesktopInstalled: { true },
            fetchUsage: { _ in nil },
            now: Date.init
        ))
        let desktopOnly = AntigravityProvider(dependencies: .init(
            findCLI: { nil },
            isDesktopInstalled: { true },
            fetchUsage: { _ in nil },
            now: Date.init
        ))

        let installedPresence = await installed.detect()
        let desktopOnlyPresence = await desktopOnly.detect()
        XCTAssertEqual(installedPresence, .ready)
        XCTAssertEqual(desktopOnlyPresence, .notSignedIn("Install AGY CLI to read usage"))
        XCTAssertEqual(
            AntigravityProvider.usageArguments,
            ["--print", "/usage", "--output-format", "json", "--print-timeout", "20s"]
        )
    }
}
