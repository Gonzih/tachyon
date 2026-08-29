import XCTest
@testable import Tachyon

/// Core value types: meters, formatting, geometry, colors, the SVG parser.
final class CoreTests: XCTestCase {

    // MARK: UsageWindow meters

    func testPercentWindowClamps() {
        XCTAssertEqual(UsageWindow(label: "w", percentUsed: 130, resetsAt: nil).percentUsed, 100)
        XCTAssertEqual(UsageWindow(label: "w", percentUsed: -5, resetsAt: nil).percentUsed, 0)
    }

    func testSpendWindowHasNoPercent() {
        let window = UsageWindow(label: "w", spendUSD: 4.2, resetsAt: nil)
        XCTAssertNil(window.percentUsed)
        XCTAssertEqual(window.spendUSD, 4.2)
        XCTAssertNil(window.budgetUSD)
    }

    func testBudgetedWindowDerivesClampedPercent() {
        let window = UsageWindow(label: "w", spendUSD: 25, budgetUSD: 50, resetsAt: nil)
        XCTAssertEqual(window.percentUsed, 50)
        let over = UsageWindow(label: "w", spendUSD: 80, budgetUSD: 50, resetsAt: nil)
        XCTAssertEqual(over.percentUsed, 100)
    }

    func testDegenerateBudgetsAreUnset() {
        for budget in [0.0, -10, .infinity, Double.nan] {
            let window = UsageWindow(label: "w", spendUSD: 5, budgetUSD: budget, resetsAt: nil)
            XCTAssertNil(window.percentUsed, "budget \(budget) must be treated as unset")
            XCTAssertNil(window.budgetUSD)
        }
    }

    func testNegativeSpendClampsToZero() {
        XCTAssertEqual(UsageWindow(label: "w", spendUSD: -3, resetsAt: nil).spendUSD, 0)
    }

    func testFormatSpend() {
        XCTAssertEqual(UsageWindow.formatSpend(0), "$0")
        XCTAssertEqual(UsageWindow.formatSpend(0.42), "$0.42")
        XCTAssertEqual(UsageWindow.formatSpend(4.2), "$4.20")
        XCTAssertEqual(UsageWindow.formatSpend(42), "$42.0")
        XCTAssertEqual(UsageWindow.formatSpend(128.4), "$128")
    }

    /// Old persisted snapshots (pre-spend fields) must still decode.
    func testWindowCodableBackwardCompatible() throws {
        let legacy = #"{"label":"Current session","percentUsed":36,"resetsAt":null}"#
        let window = try JSONDecoder().decode(UsageWindow.self, from: Data(legacy.utf8))
        XCTAssertEqual(window.percentUsed, 36)
        XCTAssertNil(window.spendUSD)
    }

    // MARK: Reset formatting

    func testResetTextBranches() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        XCTAssertNil(ResetFormat.resetText(nil, now: now))
        XCTAssertEqual(ResetFormat.resetText(now.addingTimeInterval(-60), now: now), "resetting…")
        XCTAssertEqual(ResetFormat.resetText(now.addingTimeInterval(45 * 60), now: now), "Resets in 45 min")
        XCTAssertTrue(ResetFormat.resetText(now.addingTimeInterval(30), now: now)?.hasPrefix("Resets in") ?? false)
        // Far future carries a weekday.
        let far = ResetFormat.resetText(now.addingTimeInterval(3 * 86_400), now: now)
        XCTAssertTrue(far?.hasPrefix("Resets ") ?? false)
    }

    func testRelativeFormatting() {
        let now = Date()
        XCTAssertEqual(ResetFormat.relative(now, now: now), "just now")
        XCTAssertEqual(ResetFormat.relative(now.addingTimeInterval(-120), now: now), "2m ago")
        XCTAssertEqual(ResetFormat.relative(now.addingTimeInterval(-7200), now: now), "2h ago")
    }

    // MARK: Color bands (half-open at 50/70/90)

    @MainActor func testColorBands() {
        XCTAssertEqual(UsageColor.band(0), UsageColor.green)
        XCTAssertEqual(UsageColor.band(49.9), UsageColor.green)
        XCTAssertEqual(UsageColor.band(50), UsageColor.yellow)
        XCTAssertEqual(UsageColor.band(69.9), UsageColor.yellow)
        XCTAssertEqual(UsageColor.band(70), UsageColor.orange)
        XCTAssertEqual(UsageColor.band(89.9), UsageColor.orange)
        XCTAssertEqual(UsageColor.band(90), UsageColor.red)
        XCTAssertEqual(UsageColor.band(100), UsageColor.red)
    }

    // MARK: Pill geometry

    @MainActor func testPillHeightFormula() {
        // 32 + N*56 + (N-1)*18, plus 2*24 taper margin on the panel.
        XCTAssertEqual(PillMetrics.height(moduleCount: 1), 88)
        XCTAssertEqual(PillMetrics.height(moduleCount: 2), 162)
        XCTAssertEqual(PillMetrics.height(moduleCount: 3), 236)
        XCTAssertEqual(
            PillMetrics.panelHeight(moduleCount: 2),
            PillMetrics.height(moduleCount: 2) + 48
        )
    }

    @MainActor func testModuleIndexMapsClicksToRings() {
        // First module starts after taper + padding.
        XCTAssertEqual(PillMetrics.moduleIndex(atY: 24 + 16 + 1, count: 2), 0)
        XCTAssertEqual(PillMetrics.moduleIndex(atY: 24 + 16 + 56 + 18 + 1, count: 2), 1)
        XCTAssertNil(PillMetrics.moduleIndex(atY: 5, count: 2))
    }

    // MARK: SVG path parser

    @MainActor func testEveryGlyphParsesToRealGeometry() {
        for glyph in ProviderGlyph.allCases {
            let path = SVGPath.parse(glyph.pathData)
            let box = path.boundingRect
            XCTAssertFalse(path.isEmpty, "\(glyph) parsed empty")
            XCTAssertGreaterThan(box.width, 10, "\(glyph) suspiciously small")
            XCTAssertLessThanOrEqual(box.width, glyph.viewBox.width * 1.02, "\(glyph) escapes its viewBox")
        }
    }

    @MainActor func testParserHandlesArcsAndQuads() {
        let arc = SVGPath.parse("M0 0A5 5 0 0 1 10 0Z")
        XCTAssertFalse(arc.isEmpty)
        let quad = SVGPath.parse("M0 0Q5 10 10 0")
        XCTAssertFalse(quad.isEmpty)
        // Glued arc flags, the lobehub style: "a1 1 0 00-.996 0"
        let glued = SVGPath.parse("M12 2a1 1 0 00-.996 0L2 8Z")
        XCTAssertFalse(glued.isEmpty)
    }
}
