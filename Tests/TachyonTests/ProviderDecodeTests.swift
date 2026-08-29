import XCTest
@testable import Tachyon

/// Provider payload decoding against captured-shape fixtures. Fixtures are
/// SHAPES with synthetic values — never real account data.
final class ProviderDecodeTests: XCTestCase {

    // MARK: Claude

    private let claudeFixture = """
    {
      "five_hour": {"utilization": 36.0, "resets_at": "2026-08-29T00:29:59Z"},
      "seven_day": {"utilization": 14.0, "resets_at": "2026-09-04T00:59:59Z"},
      "limits": [
        {"kind": "session", "percent": 36, "resets_at": "2026-08-29T00:29:59Z", "is_active": true},
        {"kind": "weekly_scoped", "percent": 11, "resets_at": "2026-09-04T00:59:59Z",
         "scope": {"model": {"display_name": "Fable"}}, "is_active": true},
        {"kind": "weekly_all", "percent": 9, "resets_at": null, "is_active": false}
      ]
    }
    """

    func testClaudeRingIsFiveHour() {
        let snapshot = ClaudeProvider.decode(Data(claudeFixture.utf8))
        XCTAssertEqual(snapshot?.primary.percentUsed, 36)
        XCTAssertEqual(snapshot?.primary.label, "Current session")
    }

    func testClaudeSkipsSessionAndInactiveLimits() {
        let snapshot = ClaudeProvider.decode(Data(claudeFixture.utf8))
        let labels = snapshot?.windows.map(\.label) ?? []
        // session excluded (it IS the ring), inactive weekly_all excluded,
        // scoped row labeled with the model name, seven_day fallback fires
        // because limits[] had no *active* weekly_all.
        XCTAssertTrue(labels.contains("Weekly (Fable)"))
        XCTAssertTrue(labels.contains("Weekly"))
        XCTAssertEqual(labels.filter { $0 == "Current session" }.count, 1)
    }

    func testClaudeFallsBackToSessionLimitWhenFiveHourMissing() {
        let fixture = """
        {"limits": [{"kind": "session", "percent": 62, "resets_at": null, "is_active": true}]}
        """
        let snapshot = ClaudeProvider.decode(Data(fixture.utf8))
        XCTAssertEqual(snapshot?.primary.percentUsed, 62)
    }

    func testClaudeNeverSubstitutesWeeklyIntoRing() {
        let fixture = """
        {"seven_day": {"utilization": 55.0, "resets_at": null}}
        """
        XCTAssertNil(ClaudeProvider.decode(Data(fixture.utf8)))
    }

    func testClaudeGarbageIsNilNotCrash() {
        XCTAssertNil(ClaudeProvider.decode(Data("not json".utf8)))
        XCTAssertNil(ClaudeProvider.decode(Data("{}".utf8)))
    }

    // MARK: Codex

    private let codexFixture = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_at": 1788452806},
        "secondary_window": null
      },
      "additional_rate_limits": [
        {"limit_name": "Spark",
         "rate_limit": {"primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1787964523}}},
        {"limit_name": "Busy",
         "rate_limit": {"primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1787964523}}}
      ]
    }
    """

    func testCodexRingAndWeeklyLabel() {
        let snapshot = CodexProvider.decodeUsage(Data(codexFixture.utf8), planType: nil)
        XCTAssertEqual(snapshot?.primary.percentUsed, 100)
        XCTAssertEqual(snapshot?.primary.label, "Weekly")
    }

    func testCodexHidesUntouchedSidePools() {
        let snapshot = CodexProvider.decodeUsage(Data(codexFixture.utf8), planType: nil)
        let labels = snapshot?.windows.map(\.label) ?? []
        XCTAssertFalse(labels.contains { $0.contains("Spark") }, "0% pool must stay hidden")
        XCTAssertTrue(labels.contains { $0.contains("Busy") }, "used pool must show")
    }

    func testCodexSessionLabelFromWindowSeconds() {
        let fixture = """
        {"rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": 0}}}
        """
        let snapshot = CodexProvider.decodeUsage(Data(fixture.utf8), planType: nil)
        XCTAssertEqual(snapshot?.primary.label, "Current session")
    }

    // MARK: Cursor

    private let cursorFixture = """
    {
      "planUsage": {"totalPercentUsed": 21.0, "autoPercentUsed": 5.0, "apiPercentUsed": 0.2},
      "billingCycleEnd": "2026-09-15T00:00:00Z",
      "spendLimitUsage": {"individualUsed": 12.5, "individualLimit": 50.0}
    }
    """

    func testCursorRingAndSubMeterNoise() {
        let snapshot = CursorProvider.decode(Data(cursorFixture.utf8))
        XCTAssertEqual(snapshot?.primary.percentUsed, 21)
        let labels = snapshot?.windows.map(\.label) ?? []
        XCTAssertTrue(labels.contains("Auto"), "≥1% sub-meter shows")
        XCTAssertFalse(labels.contains("API"), "sub-1% sub-meter is noise")
        XCTAssertTrue(labels.contains("Spend limit"))
    }

    func testCursorSpendLimitPercent() {
        let snapshot = CursorProvider.decode(Data(cursorFixture.utf8))
        let spendRow = snapshot?.windows.first { $0.label == "Spend limit" }
        XCTAssertEqual(spendRow?.percentUsed, 25)
    }

    // MARK: OpenRouter monthly baseline

    func testOpenRouterMonthBaseline() {
        let monthKey = "provider.openrouter.baseline.month"
        let valueKey = "provider.openrouter.baseline.usage"
        defer {
            UserDefaults.standard.removeObject(forKey: monthKey)
            UserDefaults.standard.removeObject(forKey: valueKey)
        }
        UserDefaults.standard.removeObject(forKey: monthKey)
        UserDefaults.standard.removeObject(forKey: valueKey)

        // First reading of the month becomes the baseline → spend 0.
        XCTAssertEqual(OpenRouterProvider.monthSpend(cumulative: 100), 0)
        // Growth counts.
        XCTAssertEqual(OpenRouterProvider.monthSpend(cumulative: 117.2), 17.2, accuracy: 0.001)
        // A lower cumulative (rotated key / refund) self-heals the baseline.
        XCTAssertEqual(OpenRouterProvider.monthSpend(cumulative: 5), 0)
        XCTAssertEqual(OpenRouterProvider.monthSpend(cumulative: 9), 4, accuracy: 0.001)
    }
}
