import AppKit
import CoreGraphics

/// Cheap window-geometry test: does any ordinary window sit under the pill?
///
/// Reads only frames, layer and owner PID — never window contents or titles —
/// so it needs no Screen Recording permission.
enum OverlapCheck {
    /// `pillFrame` is in AppKit coordinates (bottom-left origin); it is flipped
    /// here because `CGWindowList` reports top-left-origin global coordinates.
    static func windowOverlaps(
        pillFrame: NSRect,
        screen: NSScreen,
        ownPID: pid_t
    ) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let flippedPill = flipToCG(pillFrame)
        let flippedScreen = flipToCG(screen.frame)

        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.05 { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 1, height > 1
            else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.intersects(flippedScreen) else { continue }
            if rect.intersects(flippedPill) { return true }
        }
        return false
    }

    /// AppKit's global space has its origin at the bottom-left of the *main*
    /// screen; CGWindow's has it at the top-left. Flip about the main screen.
    private static func flipToCG(_ rect: NSRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return rect }
        let maxY = main.frame.maxY
        return CGRect(x: rect.minX, y: maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Polls `OverlapCheck` at 1Hz (plus event-driven re-checks) and publishes a
/// debounced overlap flag.
///
/// The poll stops entirely while the pill is revealed — there is nothing to
/// decide in that state, and this is the app's only recurring CPU cost.
@MainActor
final class OverlapMonitor {
    /// Transitions must hold for this long before we act, so dragging a window
    /// across the pill does not make it flap.
    private static let hysteresis: TimeInterval = 0.3
    private static let pollInterval: TimeInterval = 1.0

    private(set) var isOverlapping = false

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingValue: Bool?
    private var pendingSince: Date?
    private var paused = false

    /// Supplies the pill's current frame and screen; nil means "nothing to test".
    var frameProvider: (() -> (frame: NSRect, screen: NSScreen)?)?
    var onChange: ((Bool) -> Void)?

    func start() {
        installObservers()
        resume()
    }

    func pause() {
        guard !paused else { return }
        paused = true
        timer?.invalidate()
        timer = nil
        pendingValue = nil
        pendingSince = nil
    }

    func resume() {
        paused = false
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// Forces an immediate re-check, e.g. right after the pill moves.
    func poke() {
        guard !paused else { return }
        evaluate()
    }

    /// One synchronous reading, bypassing both the poll and the hysteresis.
    ///
    /// Needed when a decision must be made *now* against current reality — the
    /// published `isOverlapping` goes stale while the monitor is paused, which
    /// is exactly the case while the pill is revealed. Also adopts the reading
    /// so the next `resume()` does not animate in the wrong direction first.
    @discardableResult
    func evaluateNow() -> Bool {
        guard let context = frameProvider?() else { return isOverlapping }
        let observed = OverlapCheck.windowOverlaps(
            pillFrame: context.frame,
            screen: context.screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        isOverlapping = observed
        pendingValue = nil
        pendingSince = nil
        return observed
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
                MainActor.assumeIsolated { self?.poke() }
            })
        }
    }

    private func evaluate() {
        guard !paused, let context = frameProvider?() else { return }
        let observed = OverlapCheck.windowOverlaps(
            pillFrame: context.frame,
            screen: context.screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )

        guard observed != isOverlapping else {
            // Reading agrees with the published value: cancel any pending flip.
            pendingValue = nil
            pendingSince = nil
            return
        }

        if pendingValue != observed {
            pendingValue = observed
            pendingSince = Date()
            return
        }

        guard let since = pendingSince, Date().timeIntervalSince(since) >= Self.hysteresis else { return }
        isOverlapping = observed
        pendingValue = nil
        pendingSince = nil
        Log.presence.debug("Overlap → \(observed, privacy: .public)")
        onChange?(observed)
    }
}
