import AppKit
import CoreGraphics

/// What an ordinary foreign window is doing on Tachyon's chosen display.
enum WindowObstruction: Equatable {
    case none
    case overlap
    case fullScreen
}

struct WindowIdentity: Hashable {
    let ownerPID: pid_t
    let windowID: CGWindowID
}

/// A geometry reading plus the evidence needed to distinguish an empty
/// WindowServer handoff from a real return to ordinary desktop windows.
struct WindowObservation: Equatable {
    let obstruction: WindowObstruction
    let hasOrdinaryWindow: Bool
    /// A layer-0 window matching `screen.visibleFrame`. This is ambiguous on
    /// its own (ordinary maximized windows have the same shape), but it can
    /// safely continue fullscreen after exact full-frame proof in this Space.
    let fullScreenIdentity: WindowIdentity?
    let fullScreenContinuationIdentities: Set<WindowIdentity>

    var hasFullScreenContinuationGeometry: Bool {
        !fullScreenContinuationIdentities.isEmpty
    }

    init(
        obstruction: WindowObstruction,
        hasOrdinaryWindow: Bool,
        fullScreenIdentity: WindowIdentity? = nil,
        fullScreenContinuationIdentities: Set<WindowIdentity> = []
    ) {
        self.obstruction = obstruction
        self.hasOrdinaryWindow = hasOrdinaryWindow
        self.fullScreenIdentity = fullScreenIdentity
        self.fullScreenContinuationIdentities = fullScreenContinuationIdentities
    }
}

/// Keeps a proven full-screen presentation suppressed while WindowServer swaps
/// a layer-0 app window for a video/compositor surface. Proof follows the same
/// WindowServer window after a bounded same-process transition; a display
/// change or contrary ordinary geometry clears it.
struct FullScreenContinuation {
    /// Native fullscreen transitions briefly replace the app's real window
    /// with a full-display transition window owned by the same process. The
    /// replacement must happen inside this bounded compositor handoff; after
    /// that, same-process maximized geometry is ordinary again.
    private static let identityTransferWindow: TimeInterval = 2

    private struct Context: Equatable {
        let displayID: CGDirectDisplayID?
        let frame: CGRect
    }

    private var context: Context?
    private var hasProof = false
    private var proofIdentity: WindowIdentity?
    private var identityTransferDeadline: Date?

    mutating func resolve(
        _ observation: WindowObservation,
        displayID: CGDirectDisplayID?,
        screenFrame: CGRect,
        now: Date = Date()
    ) -> WindowObstruction {
        expireIdentityTransfer(at: now)
        let nextContext = Context(displayID: displayID, frame: screenFrame)
        if context != nextContext {
            context = nextContext
            clearProof()
        }

        switch observation.obstruction {
        case .fullScreen:
            if !hasProof {
                identityTransferDeadline = now.addingTimeInterval(Self.identityTransferWindow)
            }
            hasProof = true
            proofIdentity = observation.fullScreenIdentity
            return .fullScreen
        case .overlap:
            if hasProof,
               let proofIdentity,
               observation.fullScreenContinuationIdentities.contains(proofIdentity) {
                return .fullScreen
            }
            if identityTransferDeadline != nil,
               let proofIdentity,
               let replacement = observation.fullScreenContinuationIdentities.first(
                   where: { $0.ownerPID == proofIdentity.ownerPID }
               ) {
                self.proofIdentity = replacement
                return .fullScreen
            }
            clearProof()
            return .overlap
        case .none:
            if observation.hasOrdinaryWindow { clearProof() }
            return hasProof ? .fullScreen : .none
        }
    }

    /// Ends the bounded handoff allowance used during a Space animation. An
    /// empty observation may briefly inherit proof while WindowServer moves a
    /// window between Spaces, but it cannot keep an ordinary empty Space
    /// suppressed after the compositor has settled.
    mutating func resolveSettled(
        _ observation: WindowObservation,
        displayID: CGDirectDisplayID?,
        screenFrame: CGRect,
        now: Date = Date()
    ) -> WindowObstruction {
        let resolved = resolve(
            observation,
            displayID: displayID,
            screenFrame: screenFrame,
            now: now
        )
        guard resolved == .fullScreen, observation.obstruction == .none else {
            if resolved == .fullScreen { identityTransferDeadline = nil }
            return resolved
        }
        clearProof()
        return .none
    }

    /// A fresh exact-frame proof belongs to a fullscreen transition entering
    /// its destination Space. Older proof belongs to the Space being left and
    /// must not leak into the destination.
    mutating func prepareForSpaceTransition(now: Date = Date()) {
        expireIdentityTransfer(at: now)
        if identityTransferDeadline == nil { clearProof() }
    }

    mutating func reset() {
        context = nil
        clearProof()
    }

    private mutating func clearProof() {
        hasProof = false
        proofIdentity = nil
        identityTransferDeadline = nil
    }

    private mutating func expireIdentityTransfer(at now: Date) {
        if let deadline = identityTransferDeadline, now >= deadline {
            identityTransferDeadline = nil
        }
    }
}

/// Cheap window-geometry test: does an ordinary window sit under the pill, or
/// does one cover the entire chosen display?
///
/// The deliberately verbose filtering here is a privacy and portability
/// boundary. It reads only frames, layer, alpha, and owner PID — never window
/// contents, titles, or application identity — so it needs neither Screen
/// Recording nor Accessibility permission and works across native apps,
/// browsers, and video players.
enum OverlapCheck {
    private static let fullScreenTolerance: CGFloat = 2

    /// `pillFrame` is in AppKit coordinates (bottom-left origin); both frames
    /// are flipped because `CGWindowList` uses a top-left global origin.
    static func currentObstruction(
        pillFrame: NSRect,
        screen: NSScreen,
        ownPID: pid_t
    ) -> WindowObstruction {
        currentObservation(pillFrame: pillFrame, screen: screen, ownPID: ownPID).obstruction
    }

    static func currentObservation(
        pillFrame: NSRect,
        screen: NSScreen,
        ownPID: pid_t
    ) -> WindowObservation {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return WindowObservation(obstruction: .none, hasOrdinaryWindow: false)
        }

        return observe(
            windows: list,
            pillFrame: flipToCG(pillFrame),
            screenFrame: flipToCG(screen.frame),
            fullScreenContinuationFrame: flipToCG(screen.visibleFrame),
            ownPID: ownPID
        )
    }

    /// Pure classifier used by the live query and deterministic multi-display
    /// tests. All input rectangles are in CGWindow's top-left global space.
    static func classify(
        windows: [[String: Any]],
        pillFrame: CGRect,
        screenFrame: CGRect,
        ownPID: pid_t
    ) -> WindowObstruction {
        observe(
            windows: windows,
            pillFrame: pillFrame,
            screenFrame: screenFrame,
            ownPID: ownPID
        ).obstruction
    }

    static func observe(
        windows: [[String: Any]],
        pillFrame: CGRect,
        screenFrame: CGRect,
        fullScreenContinuationFrame: CGRect? = nil,
        ownPID: pid_t
    ) -> WindowObservation {
        var result = WindowObstruction.none
        var hasOrdinaryWindow = false
        var fullScreenContinuationIdentities: Set<WindowIdentity> = []

        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.05 { continue }
            guard let rect = windowFrame(info), rect.intersects(screenFrame) else { continue }
            hasOrdinaryWindow = true
            if matchesScreenBoundary(rect, screenFrame: screenFrame) {
                return WindowObservation(
                    obstruction: .fullScreen,
                    hasOrdinaryWindow: true,
                    fullScreenIdentity: windowIdentity(info)
                )
            }
            if let continuationFrame = fullScreenContinuationFrame,
               matchesScreenBoundary(rect, screenFrame: continuationFrame),
               let identity = windowIdentity(info) {
                fullScreenContinuationIdentities.insert(identity)
            }
            if rect.intersects(pillFrame) { result = .overlap }
        }
        return WindowObservation(
            obstruction: result,
            hasOrdinaryWindow: hasOrdinaryWindow,
            fullScreenContinuationIdentities: fullScreenContinuationIdentities
        )
    }

    private static func windowIdentity(_ info: [String: Any]) -> WindowIdentity? {
        guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
              let number = info[kCGWindowNumber as String] as? NSNumber
        else { return nil }
        return WindowIdentity(ownerPID: owner.int32Value, windowID: number.uint32Value)
    }

    private static func windowFrame(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 1, rect.height > 1
        else { return nil }
        return rect
    }

    /// A native full-screen window matches `screen.frame`. Do not treat
    /// `visibleFrame` as full-screen: that is also ordinary maximized terminal
    /// and editor geometry, where Tachyon must retain its useful shim. Exact
    /// per-edge matching rejects spanning and materially inset windows; the
    /// tolerance only absorbs WindowServer rounding.
    private static func matchesScreenBoundary(_ rect: CGRect, screenFrame: CGRect) -> Bool {
        guard !screenFrame.isEmpty else { return false }
        return abs(rect.minX - screenFrame.minX) <= fullScreenTolerance
            && abs(rect.minY - screenFrame.minY) <= fullScreenTolerance
            && abs(rect.maxX - screenFrame.maxX) <= fullScreenTolerance
            && abs(rect.maxY - screenFrame.maxY) <= fullScreenTolerance
    }

    /// AppKit's global space has its origin at the bottom-left of the *main*
    /// screen; CGWindow's has it at the top-left. Flip about the main screen.
    private static func flipToCG(_ rect: NSRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return rect }
        return flipToCG(rect, primaryMaxY: main.frame.maxY)
    }

    /// Pure form keeps above/below/left multi-display coordinate conversion
    /// testable without constructing `NSScreen` instances.
    static func flipToCG(_ rect: NSRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Polls `OverlapCheck` at 5Hz (plus event-driven re-checks) and publishes a
/// debounced obstruction classification.
///
/// This is the app's only recurring UI-presentation polling cost. It remains
/// active while revealed so fullscreen can always suppress visible surfaces.
@MainActor
final class OverlapMonitor {
    /// Transitions must hold for this long before we act, so dragging a window
    /// across the pill does not make it flap.
    private static let hysteresis: TimeInterval = 0.3
    /// Native fullscreen's exact screen-frame transition window lasts only a
    /// fraction of a second. Five metadata-only samples per second reliably
    /// capture it.
    private static let pollInterval: TimeInterval = 0.2

    private(set) var obstruction = WindowObstruction.none

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingValue: WindowObstruction?
    private var pendingSince: Date?
    private var eventRecheckWorkItem: DispatchWorkItem?
    private var fullScreenContinuation = FullScreenContinuation()

    /// Supplies the pill's current frame and screen; nil means "nothing to test".
    var frameProvider: (() -> (frame: NSRect, screen: NSScreen)?)?
    var onChange: ((WindowObstruction) -> Void)?

    func start() {
        installObservers()
        resume()
    }

    private func resume() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        eventRecheckWorkItem?.cancel()
        eventRecheckWorkItem = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        fullScreenContinuation.reset()
    }

    /// Forces an immediate re-check, e.g. right after the pill moves.
    func poke() {
        evaluate()
    }

    /// A physical screen change invalidates the WindowServer identity context.
    func resetFullScreenContinuation() {
        fullScreenContinuation.reset()
        pendingValue = nil
        pendingSince = nil
    }

    func prepareForSpaceTransition() {
        fullScreenContinuation.prepareForSpaceTransition()
        pendingValue = nil
        pendingSince = nil
    }

    /// One synchronous reading, bypassing both the poll and the hysteresis.
    ///
    /// Needed when a decision must be made *now* against current reality, such
    /// as a Space handoff or revealed-pill collapse. Also adopts the reading so
    /// the next poll starts from the same classification.
    @discardableResult
    func evaluateNow() -> WindowObstruction {
        evaluateNow(settlingSpaceTransition: false)
    }

    /// Final bounded Space-transition read. It differs from `evaluateNow()`
    /// only for an empty WindowServer snapshot: temporary fullscreen proof is
    /// no longer allowed to survive once the transition has settled.
    @discardableResult
    func evaluateSettledSpaceNow() -> WindowObstruction {
        evaluateNow(settlingSpaceTransition: true)
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            })
        }
    }

    /// Workspace notifications can precede the final WindowServer geometry by
    /// a frame or two. Read now, then once more after the compositor settles.
    private func environmentChanged() {
        poke()
        eventRecheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventRecheckWorkItem = nil
            self.poke()
        }
        eventRecheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func evaluate() {
        guard let context = frameProvider?() else { return }
        let observed = resolveCurrentObstruction(frame: context.frame, screen: context.screen)

        guard observed != obstruction else {
            // Reading agrees with the published value: cancel any pending flip.
            pendingValue = nil
            pendingSince = nil
            return
        }

        // Fullscreen is a visual-safety transition: hide immediately once it
        // is proven. Recovery still uses hysteresis so a compositor handoff or
        // Space animation cannot flash the pill over a movie.
        if observed == .fullScreen {
            publish(observed)
            return
        }

        if pendingValue != observed {
            pendingValue = observed
            pendingSince = Date()
            return
        }

        guard let since = pendingSince, Date().timeIntervalSince(since) >= Self.hysteresis else { return }
        publish(observed)
    }

    private func publish(_ observed: WindowObstruction) {
        obstruction = observed
        pendingValue = nil
        pendingSince = nil
        Log.presence.debug("Window obstruction → \(String(describing: observed), privacy: .public)")
        onChange?(observed)
    }

    private func evaluateNow(settlingSpaceTransition: Bool) -> WindowObstruction {
        guard let context = frameProvider?() else { return obstruction }
        let observation = OverlapCheck.currentObservation(
            pillFrame: context.frame,
            screen: context.screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let observed: WindowObstruction
        if settlingSpaceTransition {
            observed = fullScreenContinuation.resolveSettled(
                observation,
                displayID: context.screen.displayID,
                screenFrame: context.screen.frame
            )
        } else {
            observed = fullScreenContinuation.resolve(
                observation,
                displayID: context.screen.displayID,
                screenFrame: context.screen.frame
            )
        }
        obstruction = observed
        pendingValue = nil
        pendingSince = nil
        return observed
    }

    private func resolveCurrentObstruction(frame: NSRect, screen: NSScreen) -> WindowObstruction {
        let observation = OverlapCheck.currentObservation(
            pillFrame: frame,
            screen: screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        return fullScreenContinuation.resolve(
            observation,
            displayID: screen.displayID,
            screenFrame: screen.frame
        )
    }
}
