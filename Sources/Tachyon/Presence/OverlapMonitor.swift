import AppKit
import CoreGraphics

/// What an ordinary foreign window is doing on Tachyon's chosen display.
enum WindowObstruction: Equatable {
    case none
    case overlap
    case fullScreen
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
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return .none }

        return classify(
            windows: list,
            pillFrame: flipToCG(pillFrame),
            screenFrame: flipToCG(screen.frame),
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
        var result = WindowObstruction.none

        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.05 { continue }
            guard let rect = windowFrame(info), rect.intersects(screenFrame) else { continue }
            if matchesScreenBoundary(rect, screenFrame: screenFrame) {
                return .fullScreen
            }
            if rect.intersects(pillFrame) { result = .overlap }
        }
        return result
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

/// Polls `OverlapCheck` at 1Hz (plus event-driven re-checks) and publishes a
/// debounced obstruction classification.
///
/// The poll stops entirely while the pill is revealed — there is nothing to
/// decide in that state, and this is the app's only recurring CPU cost.
@MainActor
final class OverlapMonitor {
    /// Transitions must hold for this long before we act, so dragging a window
    /// across the pill does not make it flap.
    private static let hysteresis: TimeInterval = 0.3
    private static let pollInterval: TimeInterval = 1.0

    private(set) var obstruction = WindowObstruction.none

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingValue: WindowObstruction?
    private var pendingSince: Date?
    private var paused = false

    /// Supplies the pill's current frame and screen; nil means "nothing to test".
    var frameProvider: (() -> (frame: NSRect, screen: NSScreen)?)?
    var onChange: ((WindowObstruction) -> Void)?

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
    func evaluateNow() -> WindowObstruction {
        guard let context = frameProvider?() else { return obstruction }
        let observed = OverlapCheck.currentObstruction(
            pillFrame: context.frame,
            screen: context.screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        obstruction = observed
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
        let observed = OverlapCheck.currentObstruction(
            pillFrame: context.frame,
            screen: context.screen,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )

        guard observed != obstruction else {
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
        obstruction = observed
        pendingValue = nil
        pendingSince = nil
        Log.presence.debug("Window obstruction → \(String(describing: observed), privacy: .public)")
        onChange?(observed)
    }
}
