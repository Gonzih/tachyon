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

    func testObservationRetainsOrdinaryWindowEvidenceAwayFromPill() {
        let ordinary = CGRect(x: 80, y: 120, width: 900, height: 700)
        let observation = OverlapCheck.observe(
            windows: [window(ordinary)],
            pillFrame: pill,
            screenFrame: screen,
            ownPID: ownPID
        )

        XCTAssertEqual(observation.obstruction, .none)
        XCTAssertTrue(observation.hasOrdinaryWindow)
    }

    func testObservationMarksVisibleFrameAsFullscreenContinuationGeometry() {
        let visibleFrame = CGRect(x: 0, y: 33, width: screen.width, height: screen.height - 33)
        let observation = OverlapCheck.observe(
            windows: [window(visibleFrame)],
            pillFrame: pill,
            screenFrame: screen,
            fullScreenContinuationFrame: visibleFrame,
            ownPID: ownPID
        )

        XCTAssertEqual(observation.obstruction, .overlap)
        XCTAssertTrue(observation.hasOrdinaryWindow)
        XCTAssertTrue(observation.hasFullScreenContinuationGeometry)
        XCTAssertEqual(
            observation.fullScreenContinuationIdentities,
            [WindowIdentity(ownerPID: 42, windowID: 42)]
        )
    }

    func testFullScreenContinuationKeepsOnlyProvenWindowServerHandoffSuppressed() {
        var continuation = FullScreenContinuation()
        let empty = WindowObservation(obstruction: .none, hasOrdinaryWindow: false)
        let fullScreen = WindowObservation(obstruction: .fullScreen, hasOrdinaryWindow: true)

        XCTAssertEqual(resolve(empty, with: &continuation), .none)
        XCTAssertEqual(resolve(fullScreen, with: &continuation), .fullScreen)
        XCTAssertEqual(resolve(empty, with: &continuation), .fullScreen)

        let ordinaryAway = WindowObservation(obstruction: .none, hasOrdinaryWindow: true)
        XCTAssertEqual(resolve(ordinaryAway, with: &continuation), .none)
    }

    func testOrdinaryOverlapClearsFullScreenContinuation() {
        var continuation = FullScreenContinuation()
        XCTAssertEqual(resolve(
            WindowObservation(obstruction: .fullScreen, hasOrdinaryWindow: true),
            with: &continuation
        ), .fullScreen)
        XCTAssertEqual(resolve(
            WindowObservation(obstruction: .overlap, hasOrdinaryWindow: true),
            with: &continuation
        ), .overlap)
        XCTAssertEqual(resolve(
            WindowObservation(obstruction: .none, hasOrdinaryWindow: false),
            with: &continuation
        ), .none)
    }

    func testProvenFullScreenContinuesThroughVisibleFrameGeometry() {
        var continuation = FullScreenContinuation()
        let identity = WindowIdentity(ownerPID: 42, windowID: 7)
        let fullScreen = WindowObservation(
            obstruction: .fullScreen,
            hasOrdinaryWindow: true,
            fullScreenIdentity: identity
        )
        let settledFullscreen = WindowObservation(
            obstruction: .overlap,
            hasOrdinaryWindow: true,
            fullScreenContinuationIdentities: [identity]
        )

        XCTAssertEqual(resolve(fullScreen, with: &continuation), .fullScreen)
        XCTAssertEqual(resolve(settledFullscreen, with: &continuation), .fullScreen)

        continuation.reset()
        XCTAssertEqual(resolve(settledFullscreen, with: &continuation), .overlap)
    }

    func testAnotherMaximizedWindowCannotInheritFullScreenProof() {
        var continuation = FullScreenContinuation()
        let fullScreen = WindowObservation(
            obstruction: .fullScreen,
            hasOrdinaryWindow: true,
            fullScreenIdentity: WindowIdentity(ownerPID: 42, windowID: 7)
        )
        let unrelatedMaximizedWindow = WindowObservation(
            obstruction: .overlap,
            hasOrdinaryWindow: true,
            fullScreenContinuationIdentities: [WindowIdentity(ownerPID: 84, windowID: 9)]
        )

        XCTAssertEqual(resolve(fullScreen, with: &continuation), .fullScreen)
        XCTAssertEqual(resolve(unrelatedMaximizedWindow, with: &continuation), .overlap)
    }

    func testFreshFullscreenProofTransfersToSameProcessTransitionWindow() {
        var continuation = FullScreenContinuation()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let transitionWindow = WindowIdentity(ownerPID: 42, windowID: 7)
        let settledWindow = WindowIdentity(ownerPID: 42, windowID: 8)

        XCTAssertEqual(continuation.resolve(
            WindowObservation(
                obstruction: .fullScreen,
                hasOrdinaryWindow: true,
                fullScreenIdentity: transitionWindow
            ),
            displayID: 1,
            screenFrame: screen,
            now: now
        ), .fullScreen)
        XCTAssertEqual(continuation.resolve(
            WindowObservation(
                obstruction: .overlap,
                hasOrdinaryWindow: true,
                fullScreenContinuationIdentities: [settledWindow]
            ),
            displayID: 1,
            screenFrame: screen,
            now: now.addingTimeInterval(0.6)
        ), .fullScreen)
    }

    func testOldFullscreenProofCannotTransferToSameProcessMaximizedWindow() {
        var continuation = FullScreenContinuation()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(continuation.resolve(
            WindowObservation(
                obstruction: .fullScreen,
                hasOrdinaryWindow: true,
                fullScreenIdentity: WindowIdentity(ownerPID: 42, windowID: 7)
            ),
            displayID: 1,
            screenFrame: screen,
            now: now
        ), .fullScreen)
        continuation.prepareForSpaceTransition(now: now.addingTimeInterval(3))

        XCTAssertEqual(continuation.resolve(
            WindowObservation(
                obstruction: .overlap,
                hasOrdinaryWindow: true,
                fullScreenContinuationIdentities: [
                    WindowIdentity(ownerPID: 42, windowID: 8),
                ]
            ),
            displayID: 1,
            screenFrame: screen,
            now: now.addingTimeInterval(3)
        ), .overlap)
    }

    func testFullScreenContinuationResetsForANewDisplayContext() {
        var continuation = FullScreenContinuation()
        XCTAssertEqual(resolve(
            WindowObservation(obstruction: .fullScreen, hasOrdinaryWindow: true),
            with: &continuation
        ), .fullScreen)
        XCTAssertEqual(continuation.resolve(
            WindowObservation(obstruction: .none, hasOrdinaryWindow: false),
            displayID: 2,
            screenFrame: screen.offsetBy(dx: screen.width, dy: 0)
        ), .none)
    }

    func testSettledSpaceClearsFullscreenProofFromAnEmptyHandoff() {
        var continuation = FullScreenContinuation()
        let identity = WindowIdentity(ownerPID: 42, windowID: 7)
        XCTAssertEqual(resolve(
            WindowObservation(
                obstruction: .fullScreen,
                hasOrdinaryWindow: true,
                fullScreenIdentity: identity
            ),
            with: &continuation
        ), .fullScreen)

        XCTAssertEqual(continuation.resolveSettled(
            WindowObservation(obstruction: .none, hasOrdinaryWindow: false),
            displayID: 1,
            screenFrame: screen
        ), .none)
        XCTAssertEqual(resolve(
            WindowObservation(obstruction: .none, hasOrdinaryWindow: false),
            with: &continuation
        ), .none)
    }

    func testSettledSpaceRetainsFullscreenForTheProvenWindowIdentity() {
        var continuation = FullScreenContinuation()
        let identity = WindowIdentity(ownerPID: 42, windowID: 7)
        XCTAssertEqual(resolve(
            WindowObservation(
                obstruction: .fullScreen,
                hasOrdinaryWindow: true,
                fullScreenIdentity: identity
            ),
            with: &continuation
        ), .fullScreen)

        XCTAssertEqual(continuation.resolveSettled(
            WindowObservation(
                obstruction: .overlap,
                hasOrdinaryWindow: true,
                fullScreenContinuationIdentities: [identity]
            ),
            displayID: 1,
            screenFrame: screen
        ), .fullScreen)
    }

    @MainActor
    func testObstructionMapsToDistinctRestingPresentation() {
        XCTAssertEqual(EdgeController.restingState(for: .none), .docked)
        XCTAssertEqual(EdgeController.restingState(for: .overlap), .shim)
        XCTAssertEqual(EdgeController.restingState(for: .fullScreen), .suppressed)
        XCTAssertTrue(EdgeController.PresenceState.suppressed.keepsPillOffEdge)
        XCTAssertTrue(EdgeController.PresenceState.shim.acceptsEdgeReveal)
        XCTAssertFalse(EdgeController.PresenceState.suppressed.acceptsEdgeReveal)
        XCTAssertFalse(EdgeController.PresenceState.docked.acceptsEdgeReveal)
        XCTAssertFalse(EdgeController.PresenceState.revealed.acceptsEdgeReveal)
    }

    @MainActor
    func testFullScreenSuppressionOverridesActiveInteraction() {
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .docked,
            interactionActive: true
        ), .suppressed)
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .revealed,
            interactionActive: false
        ), .suppressed)
        XCTAssertEqual(EdgeController.automaticTarget(
            for: .fullScreen,
            from: .docked,
            interactionActive: false
        ), .suppressed)
        XCTAssertNil(EdgeController.automaticTarget(
            for: .overlap,
            from: .revealed,
            interactionActive: true
        ))
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
    func testSpaceChangePreservesRevealExceptOnFullScreenDestination() {
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .revealed,
            obstruction: .none,
            interactionActive: false
        ), .revealed)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .revealed,
            obstruction: .overlap,
            interactionActive: false
        ), .revealed)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .revealed,
            obstruction: .fullScreen,
            interactionActive: true
        ), .suppressed)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .docked,
            obstruction: .overlap,
            interactionActive: false
        ), .shim)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .docked,
            obstruction: .overlap,
            interactionActive: true
        ), .docked)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .suppressed,
            obstruction: .overlap,
            interactionActive: false
        ), .shim)
        XCTAssertEqual(EdgeController.stateAfterSpaceChange(
            from: .suppressed,
            obstruction: .none,
            interactionActive: false
        ), .docked)
    }

    @MainActor
    func testScreenPointConvertsToFlippedPillCoordinates() {
        let frame = NSRect(x: 100, y: 200, width: 64, height: 120)
        XCTAssertEqual(
            EdgeController.pillLocalPoint(at: NSPoint(x: 112, y: 300), in: frame),
            NSPoint(x: 12, y: 20)
        )
        XCTAssertNil(EdgeController.pillLocalPoint(
            at: NSPoint(x: frame.minX - 1, y: frame.midY),
            in: frame
        ))
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
            XCTAssertEqual(panel.hidesOnDeactivate, OverlayPanelPolicy.hidesOnDeactivate)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertEqual(panel.isFloatingPanel, OverlayPanelPolicy.isFloatingPanel)
            XCTAssertTrue(panel.isFloatingPanel)
        }
        XCTAssertTrue(panels[0].acceptsMouseMovedEvents)
        XCTAssertFalse(panels[1].acceptsMouseMovedEvents)
        XCTAssertTrue(panels[2].acceptsMouseMovedEvents)
    }

    @MainActor
    func testSpaceSurfaceRepairIsBoundedToFirstFailedSettlement() {
        XCTAssertFalse(EdgeController.shouldRepairSpaceSurfaces(
            settlementAttempt: 0,
            panelsAreReady: true
        ))
        XCTAssertTrue(EdgeController.shouldRepairSpaceSurfaces(
            settlementAttempt: 0,
            panelsAreReady: false
        ))
        XCTAssertFalse(EdgeController.shouldRepairSpaceSurfaces(
            settlementAttempt: 1,
            panelsAreReady: false
        ))
        XCTAssertFalse(EdgeController.shouldRepairSpaceSurfaces(
            settlementAttempt: 2,
            panelsAreReady: false
        ))
    }

    private func resolve(
        _ observation: WindowObservation,
        with continuation: inout FullScreenContinuation
    ) -> WindowObstruction {
        continuation.resolve(observation, displayID: 1, screenFrame: screen)
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
        layer: Int = 0,
        windowID: CGWindowID = 42
    ) -> [String: Any] {
        [
            kCGWindowBounds as String: frame.dictionaryRepresentation,
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String: windowID,
            kCGWindowAlpha as String: alpha,
            kCGWindowLayer as String: layer,
        ]
    }
}
