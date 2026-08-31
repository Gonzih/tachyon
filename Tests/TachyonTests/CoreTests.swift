import XCTest
@testable import Tachyon

/// Core value types: meters, formatting, geometry, colors, the SVG parser.
final class CoreTests: XCTestCase {
    func testHTTPHeadersRejectControlUnicodeAndOversizedValues() {
        XCTAssertTrue(Usage.headersAreSafe([
            "Authorization": "Bearer synthetic-token_123",
            "User-Agent": "tachyon/dev",
        ]))
        XCTAssertFalse(Usage.headersAreSafe(["Bad Name": "value"]))
        XCTAssertFalse(Usage.headersAreSafe(["Authorization": "Bearer line\nbreak"]))
        XCTAssertFalse(Usage.headersAreSafe(["Authorization": "Bearer tab\tvalue"]))
        XCTAssertFalse(Usage.headersAreSafe(["Authorization": "Bearer café"]))
        XCTAssertFalse(Usage.headersAreSafe([
            "Authorization": String(repeating: "x", count: 128 * 1024 + 1),
        ]))
    }

    func testHTTPResponseCollectorHasStrictByteLimit() async throws {
        func stream(count: Int) -> AsyncStream<UInt8> {
            AsyncStream { continuation in
                for index in 0..<count {
                    continuation.yield(UInt8(truncatingIfNeeded: index))
                }
                continuation.finish()
            }
        }

        let exact = try await Usage.boundedData(from: stream(count: 64), maximumBytes: 64)
        XCTAssertEqual(exact.count, 64)
        do {
            _ = try await Usage.boundedData(from: stream(count: 65), maximumBytes: 64)
            XCTFail("oversized response should be rejected")
        } catch Usage.HTTPRequestError.responseTooLarge {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBoundedLocalFileAndTailHelpersRejectOversizedInputs() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-bounded-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data(repeating: 0x61, count: 64)
        try payload.write(to: file)

        XCTAssertEqual(Usage.boundedFile(path: file.path, maximumBytes: 64), payload)
        XCTAssertNil(Usage.boundedFile(path: file.path, maximumBytes: 63))
        XCTAssertNil(Usage.boundedFile(path: file.path, maximumBytes: 0))
        XCTAssertEqual(Usage.tailLines(path: file.path, byteCount: -1), [])
        XCTAssertEqual(Usage.tailLines(path: file.path, byteCount: .max), [])
        XCTAssertNil(Usage.decodeJWTPayload(String(repeating: "x", count: 256 * 1024 + 1)))
    }

    func testCommandRunnerBoundsOutput() {
        XCTAssertEqual(
            Usage.runCommand(
                "/usr/bin/printf", ["synthetic-output"],
                timeout: 1, maximumOutputBytes: 64),
            "synthetic-output"
        )
        XCTAssertNil(Usage.runCommand(
            "/usr/bin/yes", ["synthetic"],
            timeout: 1, maximumOutputBytes: 1024
        ))
    }

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
        XCTAssertFalse(over.isPaceHot, "personal budgets are not provider capacity walls")
        XCTAssertEqual(over.bandPercent, 100, "the budget can still use the red color band")
        XCTAssertNil(PaceFormat.caption(for: over))
        XCTAssertEqual(
            PaceFormat.caption(for: UsageWindow(
                label: "hard",
                percentUsed: 100,
                resetsAt: nil
            )),
            "Limit reached"
        )
    }

    func testPacePresentationCentralizesCoolHotAndStaleBehavior() {
        let now = Date()
        let cool = UsageWindow(
            label: "Cool",
            percentUsed: 30,
            resetsAt: now.addingTimeInterval(500),
            windowSeconds: 1_000
        )
        let hot = UsageWindow(
            label: "Hot",
            percentUsed: 60,
            resetsAt: now.addingTimeInterval(500),
            windowSeconds: 1_000
        )

        let coolPresentation = PacePresentation(window: cool, isStale: false)
        XCTAssertEqual(coolPresentation.caption, "At this pace, ~60% by reset")
        XCTAssertEqual(coolPresentation.bandPercent, 30)
        XCTAssertFalse(coolPresentation.isHot)

        let hotPresentation = PacePresentation(window: hot, isStale: false)
        XCTAssertEqual(hotPresentation.caption, "At this pace, limit before reset")
        XCTAssertEqual(hotPresentation.bandPercent, 70)
        XCTAssertTrue(hotPresentation.isHot)

        let early = UsageWindow(
            label: "Early", percentUsed: 13,
            resetsAt: now.addingTimeInterval(589_200),
            windowSeconds: 7 * 24 * 60 * 60
        )
        let earlyPresentation = PacePresentation(window: early, isStale: false)
        XCTAssertEqual(earlyPresentation.caption, "At this pace, limit before reset")
        XCTAssertEqual(earlyPresentation.bandPercent, 13)
        XCTAssertFalse(earlyPresentation.isHot)

        let stalePresentation = PacePresentation(window: hot, isStale: true)
        XCTAssertNil(stalePresentation.caption)
        XCTAssertEqual(stalePresentation.bandPercent, 60)
        XCTAssertFalse(stalePresentation.isHot)
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
        XCTAssertEqual(UsageWindow(label: "w", spendUSD: .infinity, resetsAt: nil).spendUSD, 0)
        XCTAssertEqual(UsageWindow(label: "w", spendUSD: .nan, resetsAt: nil).spendUSD, 0)
    }

    func testFormatSpend() {
        XCTAssertEqual(UsageWindow.formatSpend(0), "$0")
        XCTAssertEqual(UsageWindow.formatSpend(0.42), "$0.42")
        XCTAssertEqual(UsageWindow.formatSpend(4.2), "$4.20")
        XCTAssertEqual(UsageWindow.formatSpend(42), "$42.0")
        XCTAssertEqual(UsageWindow.formatSpend(128.4), "$128")
        XCTAssertEqual(UsageWindow.formatSpend(.infinity), "$0")
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

    // MARK: Pace projection & band escalation (CONTRIBUTING §"The ring rule")

    func testPaceProjectionAndEscalation() {
        // Half the week elapsed, 55% used → on pace for ~110 → lift one
        // band: yellow territory colors as orange. Number stays 55.
        let onPace = UsageWindow(
            label: "Weekly", percentUsed: 55,
            resetsAt: Date().addingTimeInterval(302_400), windowSeconds: 604_800)
        XCTAssertEqual(onPace.projectedAtReset ?? 0, 110, accuracy: 1)
        XCTAssertEqual(onPace.bandPercent, 70)
        XCTAssertEqual(onPace.percentUsed, 55)
        XCTAssertTrue(onPace.isPaceHot, "hot flag drives the ring/shim pulse")

        // Same point in the window at 30% → projected 60 → no escalation.
        let underPace = UsageWindow(
            label: "Weekly", percentUsed: 30,
            resetsAt: Date().addingTimeInterval(302_400), windowSeconds: 604_800)
        XCTAssertEqual(underPace.bandPercent, 30)

        // Exhausted remains hot: switching accounts is still a useful action.
        let dead = UsageWindow(
            label: "Weekly", percentUsed: 100,
            resetsAt: Date().addingTimeInterval(302_400), windowSeconds: 604_800)
        XCTAssertTrue(dead.isPaceHot)
    }

    func testPaceNeedsSignal() {
        // Only 4% of the window elapsed — the numerical projection and visual
        // escalation stay suppressed, but 20% of a real quota is enough to
        // surface the qualitative runway warning.
        let early = UsageWindow(
            label: "Weekly", percentUsed: 20,
            resetsAt: Date().addingTimeInterval(580_608), windowSeconds: 604_800)
        XCTAssertNil(early.projectedAtReset)
        XCTAssertEqual(PaceFormat.caption(for: early), "At this pace, limit before reset")
        XCTAssertEqual(early.bandPercent, 20)
        XCTAssertFalse(early.isPaceHot)

        // A tiny early sample does not create a warning merely because a
        // point-in-time rate would look high.
        let tinyEarly = UsageWindow(
            label: "Weekly", percentUsed: 5,
            resetsAt: Date().addingTimeInterval(580_608), windowSeconds: 604_800)
        XCTAssertNil(PaceFormat.caption(for: tinyEarly))
        XCTAssertFalse(tinyEarly.isPaceHot)

        // No known duration → no projection, band judges the raw percent.
        let unknown = UsageWindow(
            label: "Window", percentUsed: 80, resetsAt: Date().addingTimeInterval(60))
        XCTAssertNil(unknown.projectedAtReset)
        XCTAssertEqual(unknown.bandPercent, 80)
    }

    func testWorstFirstRule() {
        let hardLow = UsageWindow(label: "Session", percentUsed: 20, resetsAt: nil)
        let hardHigh = UsageWindow(label: "Weekly", percentUsed: 70, resetsAt: nil)
        let budget = UsageWindow(label: "Month", spendUSD: 95, budgetUSD: 100, resetsAt: nil)

        // Worst hard window moves to the front — index 0 is the ring.
        XCTAssertEqual([budget, hardLow, hardHigh].worstFirst().first?.label, "Weekly")
        // A budget-derived 95% is synthetic and never outranks a hard limit.
        XCTAssertEqual([budget, hardLow].worstFirst().first?.label, "Session")
        // No hard windows → order untouched.
        XCTAssertEqual([budget].worstFirst().first?.label, "Month")
    }

    func testStatusSummaryIncludesOnlyProviderHardWalls() {
        let hardLow = UsageWindow(label: "Session", percentUsed: 20, resetsAt: nil)
        let hardHigh = UsageWindow(label: "Weekly", percentUsed: 70, resetsAt: nil)
        let personalBudget = UsageWindow(
            label: "Month", spendUSD: 95, budgetUSD: 100, resetsAt: nil)
        let spend = UsageWindow(label: "All time", spendUSD: 500, resetsAt: nil)
        let count = UsageWindow(label: "Today", count: 12, unit: "requests", resetsAt: nil)

        XCTAssertEqual(
            StatusSummary.closestHardWallPercent(
                in: [personalBudget, hardLow, count, hardHigh, spend]
            ),
            70
        )
        XCTAssertNil(StatusSummary.closestHardWallPercent(
            in: [personalBudget, spend, count]
        ))

        let liveSnapshot = UsageSnapshot(
            primary: hardLow, windows: [hardLow], asOf: Date(), detail: nil)
        let staleSnapshot = UsageSnapshot(
            primary: hardHigh, windows: [hardHigh], asOf: Date(), detail: nil)
        XCTAssertEqual(StatusSummary.closestLiveHardWallPercent(in: [
            .ok(liveSnapshot),
            .stale(staleSnapshot, asOf: staleSnapshot.asOf),
            .unavailable,
        ]), 20)
        XCTAssertNil(StatusSummary.closestLiveHardWallPercent(in: [
            .stale(staleSnapshot, asOf: staleSnapshot.asOf),
            .unavailable,
        ]))
    }

    // MARK: Strict provider boundaries

    func testJSONValueDoesNotBridgeBooleansAndNumbers() {
        XCTAssertNil(JSONValue(true).double)
        XCTAssertNil(JSONValue(false).int)
        XCTAssertNil(JSONValue(1).bool)
        XCTAssertNil(JSONValue(NSNumber(value: 0)).bool)
        XCTAssertEqual(JSONValue(true).bool, true)
        XCTAssertEqual(JSONValue(NSNumber(value: 42)).double, 42)
    }

    func testJSONValueRejectsNonFiniteAndOutOfRangeNumbers() {
        for value in ["Infinity", "-Infinity", "NaN"] {
            XCTAssertNil(JSONValue(value).double)
        }
        XCTAssertNil(JSONValue(Double(Int.max)).int)
        XCTAssertNil(JSONValue(Double.greatestFiniteMagnitude).int)
        XCTAssertNil(JSONValue(-Double.greatestFiniteMagnitude).int)
        XCTAssertNil(JSONValue(Double.greatestFiniteMagnitude).epochDate)
    }

    func testWindowRejectsInvalidDuration() {
        XCTAssertNil(UsageWindow(
            label: "w", percentUsed: 20, resetsAt: Date(), windowSeconds: .infinity
        ).windowSeconds)
        XCTAssertNil(UsageWindow(
            label: "w", percentUsed: 20, resetsAt: Date(), windowSeconds: -1
        ).windowSeconds)
    }

    func testOpaqueAccountIdentityIsStableOnlyForMatchingComponents() {
        let first = OpaqueAccountIdentity.fingerprint(
            namespace: "test-provider", components: ["account-a", "pool-a"])
        let same = OpaqueAccountIdentity.fingerprint(
            namespace: "test-provider", components: ["account-a", "pool-a"])
        let otherPool = OpaqueAccountIdentity.fingerprint(
            namespace: "test-provider", components: ["account-a", "pool-b"])

        XCTAssertNotNil(first)
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherPool)
        XCTAssertFalse(first?.contains("account-a") ?? true)
        XCTAssertNotEqual(
            OpaqueAccountIdentity.fingerprint(
                namespace: "test-provider", components: ["account-a\0pool-a"]),
            OpaqueAccountIdentity.fingerprint(
                namespace: "test-provider", components: ["account-a", "pool-a"])
        )
        XCTAssertNil(OpaqueAccountIdentity.fingerprint(
            namespace: "test-provider", components: ["account-a", " "]))
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

    func testCountRingAccessibilityIncludesItsUnit() {
        XCTAssertEqual(
            RingAccessibility.label(
                name: "Ollama",
                displayedValue: "42",
                count: 42,
                countUnit: "requests",
                isStale: false
            ),
            "Ollama 42 requests used"
        )
    }

    func testStatusSummaryIncludesSecondaryLiveHardWall() {
        let spend = UsageWindow(label: "Credits", spendUSD: 12, resetsAt: nil)
        let hardLimit = UsageWindow(label: "Key limit", percentUsed: 84, resetsAt: nil)
        let snapshot = UsageSnapshot(
            primary: spend,
            windows: [spend, hardLimit],
            asOf: Date(),
            detail: nil
        )

        XCTAssertEqual(StatusSummary.closestLiveHardWallPercent(in: [.ok(snapshot)]), 84)
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

    @MainActor func testParserHandlesCompactExponentNumbersAndImplicitLines() {
        // A second dot starts the next number, signs can follow exponents, and
        // coordinate pairs after moveto implicitly become line segments.
        let path = SVGPath.parse("M1.5.5 2e+1-3E+0")
        let bounds = path.boundingRect

        XCTAssertEqual(bounds.minX, 1.5, accuracy: 0.0001)
        XCTAssertEqual(bounds.minY, -3, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxX, 20, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxY, 0.5, accuracy: 0.0001)
    }
}
