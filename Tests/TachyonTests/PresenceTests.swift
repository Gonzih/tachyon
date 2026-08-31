import AppKit
import CoreGraphics
import XCTest
@testable import Tachyon

final class PresenceTests: XCTestCase {
    private let ownPID: pid_t = 9_001
    private let screen = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)
    private let pill = CGRect(x: 1_664, y: 480, width: 64, height: 157)

    func testFullScreenWindowOnSelectedDisplayIsClassifiedSeparately() {
        XCTAssertEqual(classify([window(screen)]), .fullScreen)
    }

    func testFullScreenWindowOnAnotherDisplayIsIgnored() {
        let otherDisplay = CGRect(x: 1_728, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(classify([window(otherDisplay)]), .none)
    }

    func testOtherDisplayFullScreenDoesNotMaskSelectedDisplayOverlap() {
        let otherDisplay = CGRect(x: 1_728, y: 0, width: 1_920, height: 1_080)
        let selectedOverlap = CGRect(x: 1_600, y: 430, width: 128, height: 260)
        XCTAssertEqual(
            classify([window(otherDisplay), window(selectedOverlap)]),
            .overlap
        )
    }

    func testNegativeOriginSelectedDisplayIsHandledInGlobalCoordinates() {
        let selected = CGRect(x: -1_920, y: 37, width: 1_920, height: 1_080)
        let selectedPill = CGRect(x: -64, y: 500, width: 64, height: 157)
        XCTAssertEqual(OverlapCheck.classify(
            windows: [window(selected)],
            pillFrame: selectedPill,
            screenFrame: selected,
            ownPID: ownPID
        ), .fullScreen)
    }

    func testAppKitToCGConversionHandlesDisplaysAroundPrimary() {
        let primaryMaxY: CGFloat = 1_117
        XCTAssertEqual(
            OverlapCheck.flipToCG(
                CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                primaryMaxY: primaryMaxY
            ),
            CGRect(x: -1_920, y: 37, width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            OverlapCheck.flipToCG(
                CGRect(x: 0, y: 1_117, width: 1_920, height: 1_080),
                primaryMaxY: primaryMaxY
            ),
            CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            OverlapCheck.flipToCG(
                CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080),
                primaryMaxY: primaryMaxY
            ),
            CGRect(x: 0, y: 1_117, width: 1_920, height: 1_080)
        )
    }

    func testMaximizedWindowMatchingVisibleFrameRemainsOrdinaryOverlap() {
        let visibleFrame = CGRect(x: 0, y: 33, width: screen.width, height: screen.height - 33)
        XCTAssertEqual(classify([window(visibleFrame)]), .overlap)
    }

    func testMaximizedWindowWithSideAndBottomDockRemainsOrdinaryOverlap() {
        let visibleFrame = CGRect(x: 80, y: 33, width: screen.width - 80, height: screen.height - 113)
        XCTAssertEqual(classify([window(visibleFrame)]), .overlap)
    }

    func testFullScreenToleratesRoundingAndOutranksOrdinaryOverlap() {
        let ordinary = CGRect(x: 1_600, y: 430, width: 128, height: 260)
        let rounded = screen.insetBy(dx: 1, dy: 1)
        XCTAssertEqual(classify([window(ordinary), window(rounded)]), .fullScreen)
    }

    func testMateriallyInsetWindowIsNotFullScreen() {
        let inset = screen.insetBy(dx: 8, dy: 8)
        XCTAssertEqual(classify([window(inset)]), .overlap)
    }

    func testSpanningWindowIsNotMistakenForSelectedDisplayFullScreen() {
        let spanning = CGRect(x: -120, y: 0, width: screen.width + 240, height: screen.height)
        XCTAssertEqual(classify([window(spanning)]), .overlap)
    }

    func testOwnTransparentAndElevatedFullScreenWindowsAreIgnored() {
        let windows = [
            window(screen, pid: ownPID),
            window(screen, alpha: 0.01),
            window(screen, layer: 3),
        ]
        XCTAssertEqual(classify(windows), .none)
    }

    @MainActor
    func testObstructionMapsToDistinctRestingPresentation() {
        XCTAssertEqual(EdgeController.restingState(for: .none), .docked)
        XCTAssertEqual(EdgeController.restingState(for: .overlap), .shim)
        XCTAssertEqual(EdgeController.restingState(for: .fullScreen), .suppressed)
        XCTAssertTrue(EdgeController.PresenceState.suppressed.keepsPillOffEdge)
    }

    @MainActor
    func testActiveInteractionDefersFullScreenSuppression() {
        XCTAssertNil(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .docked,
            interactionActive: true
        ))
        XCTAssertNil(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .revealed,
            interactionActive: false
        ))
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .docked,
            interactionActive: false
        ), .suppressed)
    }

    @MainActor
    func testSuppressedPresentationRecoversToLatestObstruction() {
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .overlap,
            from: .suppressed,
            interactionActive: false
        ), .shim)
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .none,
            from: .suppressed,
            interactionActive: false
        ), .docked)
    }

    @MainActor
    func testEveryOverlayPanelUsesCrossApplicationSpaceBehavior() {
        _ = NSApplication.shared
        let panels: [NSPanel] = [
            PillPanel(contentRect: .zero),
            ShimPanel(),
            PopoverPanel(),
        ]

        for panel in panels {
            XCTAssertEqual(panel.collectionBehavior, OverlayPanelPolicy.collectionBehavior)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
            XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary))
        }
    }

    private func classify(_ windows: [[String: Any]]) -> WindowObstruction {
        OverlapCheck.classify(
            windows: windows,
            pillFrame: pill,
            screenFrame: screen,
            ownPID: ownPID
        )
    }

    private func window(
        _ frame: CGRect,
        pid: pid_t = 42,
        alpha: Double = 1,
        layer: Int = 0
    ) -> [String: Any] {
        [
            kCGWindowBounds as String: frame.dictionaryRepresentation,
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
            kCGWindowLayer as String: layer,
        ]
    }
}
