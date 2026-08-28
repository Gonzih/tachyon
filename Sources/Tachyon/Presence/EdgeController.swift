import AppKit
import SwiftUI

/// Owns the pill, shim and popover, and runs the docked → shim → revealed
/// state machine.
///
/// Timing constants are all distinct on purpose, so a stall is attributable:
/// overlap hysteresis 300ms (in `OverlapMonitor`), hover dwell 150ms, reveal
/// collapse 500ms, popover open 300ms, popover exit grace 200ms.
@MainActor
final class EdgeController {
    /// The app layer supplies the context menu (same one as the status item).
    var onPillRightClick: ((NSEvent, NSView) -> Void)?

    enum PresenceState {
        case docked
        case shim
        case revealed
    }

    // Timings (seconds).
    private static let hoverDwell: TimeInterval = 0.15
    private static let revealCollapse: TimeInterval = 0.5
    private static let popoverOpenDelay: TimeInterval = 0.3
    private static let popoverExitGrace: TimeInterval = 0.2
    /// Width of the edge strip that arms the reveal.
    private static let hotZoneWidth: CGFloat = 12
    private static let slideOutDuration: TimeInterval = 0.25
    private static let slideInDuration: TimeInterval = 0.3

    private(set) var state: PresenceState = .docked

    private let model: UsageModel
    private let pill: PillPanel
    private let shim = ShimPanel()
    private let popover = PopoverPanel()
    private let overlap = OverlapMonitor()
    private var hostView: TrackingHostView<PillView>

    private var globalMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private var dwellWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var popoverOpenWorkItem: DispatchWorkItem?
    private var popoverCloseWorkItem: DispatchWorkItem?

    private var pointerInPill = false
    private var pointerInPopover = false
    /// Module index the pointer is currently over, if any.
    private var hoveredIndex: Int?

    private var visibleSlots: [ProviderSlot] { model.visibleSlots }

    init(model: UsageModel) {
        self.model = model
        self.pill = PillPanel(contentRect: NSRect(x: 0, y: 0, width: PillMetrics.width, height: 88))
        self.hostView = TrackingHostView(rootView: PillView(slots: []))
        pill.contentView = hostView

        hostView.onEnter = { [weak self] in self?.pillPointer(inside: true) }
        hostView.onExit = { [weak self] in self?.pillPointer(inside: false) }
        hostView.onMove = { [weak self] point in self?.pillPointerMoved(to: point) }
        hostView.onClick = { [weak self] point in self?.pillClicked(at: point) }
        hostView.onRightClick = { [weak self] event in
            guard let self else { return }
            self.onPillRightClick?(event, self.hostView)
        }

        popover.onPointerInside = { [weak self] inside in self?.popoverPointer(inside: inside) }
        popover.onDismiss = { [weak self] in self?.closePopover() }
        // A click on the pill is the ring's business (it may be the second click
        // that closes the popover), never a click-away dismissal.
        popover.excludedFrames = { [weak self] in
            guard let self, self.pill.isVisible else { return [] }
            return [self.pill.frame]
        }

        overlap.frameProvider = { [weak self] in
            guard let self, let screen = self.currentScreen else { return nil }
            return (self.bodyFrame(on: screen), screen)
        }
        overlap.onChange = { [weak self] overlapping in self?.overlapChanged(overlapping) }
    }

    // MARK: Lifecycle

    func start() {
        rebuild()
        installGlobalMouseMonitor()
        installScreenObserver()
        overlap.start()
    }

    func stop() {
        overlap.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        cancelAllTimers()
        popover.dismiss()
        pill.orderOut(nil)
        shim.orderOut(nil)
    }

    /// Re-reads the model and repositions everything. Cheap enough to call on
    /// every snapshot.
    func rebuild() {
        let slots = visibleSlots
        hostView.rootView = PillView(slots: slots)
        shim.update(slots: slots)

        guard !slots.isEmpty, let screen = currentScreen else {
            // Nothing to show: the status item is the way back.
            pill.orderOut(nil)
            shim.orderOut(nil)
            popover.dismiss()
            return
        }

        shim.position(on: screen, moduleCount: slots.count)
        applyFrame(for: state, on: screen, animated: false)
        placePanels(for: state)

        // Keep an open popover in sync with fresh numbers.
        if let id = popover.targetProviderID, let slot = model.slot(id: id) {
            popover.refresh(slot: slot)
        }
        overlap.poke()
    }

    // MARK: Geometry

    private var currentScreen: NSScreen? { NSScreen.preferred() }

    private var moduleCount: Int { visibleSlots.count }

    /// Pill frame when fully visible: flush to the right edge, vertically centered.
    /// The panel is a corner-radius taller than the body at each end, so the
    /// concave tapers are not clipped away.
    private func dockedFrame(on screen: NSScreen) -> NSRect {
        let panelHeight = PillMetrics.panelHeight(moduleCount: moduleCount)
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - PillMetrics.width,
            y: visible.midY - panelHeight / 2,
            width: PillMetrics.width,
            height: panelHeight
        )
    }

    /// The pill's visible body, excluding the taper margins. This is what the
    /// overlap test cares about — a window brushing the transparent margin is
    /// not covering anything.
    private func bodyFrame(on screen: NSScreen) -> NSRect {
        dockedFrame(on: screen).insetBy(dx: 0, dy: PillMetrics.cornerRadius)
    }

    /// Off-edge resting place. Offset by the full panel width so the pill clears
    /// the screen entirely: parking it at `maxX` alone leaves the whole 64pt
    /// panel sitting in the strip to the right, which is a neighbouring display
    /// in a multi-monitor layout rather than empty space.
    private func hiddenFrame(on screen: NSScreen) -> NSRect {
        var frame = dockedFrame(on: screen)
        frame.origin.x = screen.visibleFrame.maxX + PillMetrics.width
        return frame
    }

    private func applyFrame(for state: PresenceState, on screen: NSScreen, animated: Bool) {
        let target = state == .shim ? hiddenFrame(on: screen) : dockedFrame(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            pill.setFrame(target, display: true)
            return
        }
        let duration = state == .shim ? Self.slideOutDuration : Self.slideInDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // Departures accelerate away, arrivals decelerate in — and the
            // slide is a pure translation, so the content never needs to
            // redisplay mid-flight (display: false). The window server moves
            // the layer and its shadow wholesale; nothing re-renders per frame.
            context.timingFunction = CAMediaTimingFunction(
                name: state == .shim ? .easeIn : .easeOut
            )
            context.allowsImplicitAnimation = true
            pill.animator().setFrame(target, display: false)
        }
    }

    private func placePanels(for state: PresenceState) {
        guard moduleCount > 0 else { return }
        switch state {
        case .docked, .revealed:
            shim.orderOut(nil)
            pill.orderFrontRegardless()
        case .shim:
            pill.orderOut(nil)
            shim.orderFrontRegardless()
        }
    }

    // MARK: State machine

    private func transition(to next: PresenceState) {
        guard next != state, moduleCount > 0, let screen = currentScreen else { return }
        let previous = state
        state = next
        Log.presence.debug("State \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)")

        switch next {
        case .shim:
            // Slide out first, then swap in the shim so there is no visible gap.
            shim.position(on: screen, moduleCount: moduleCount)
            shim.orderFrontRegardless()
            applyFrame(for: .shim, on: screen, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOutDuration) { [weak self] in
                guard let self, self.state == .shim else { return }
                self.pill.orderOut(nil)
            }
            popover.dismiss()
            pointerInPopover = false
            overlap.resume()

        case .revealed:
            // Nothing to decide while revealed — stop the 1Hz poll entirely.
            overlap.pause()
            shim.orderOut(nil)
            pill.setFrame(hiddenFrame(on: screen), display: false)
            pill.orderFrontRegardless()
            applyFrame(for: .revealed, on: screen, animated: true)
            // The pill slides out from under the pointer, so no enter event is
            // guaranteed. Once it has landed, decide from the actual pointer
            // position whether the collapse clock should already be running.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideInDuration) { [weak self] in
                guard let self, self.state == .revealed else { return }
                self.revealedPointerMoved(NSEvent.mouseLocation)
            }

        case .docked:
            overlap.resume()
            pill.orderFrontRegardless()
            if previous == .shim {
                // Slide in from off-screen; keep the shim up until the pill
                // lands so the edge is never bare mid-transition.
                pill.setFrame(hiddenFrame(on: screen), display: false)
                applyFrame(for: .docked, on: screen, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideInDuration) { [weak self] in
                    guard let self, self.state == .docked else { return }
                    self.shim.orderOut(nil)
                }
            } else {
                shim.orderOut(nil)
                applyFrame(for: .docked, on: screen, animated: previous == .revealed)
            }
        }
    }

    /// Where a collapse from `.revealed` should land.
    ///
    /// The monitor is paused while revealed, so its published flag is frozen at
    /// the value that caused the shim in the first place. Re-read it: the user
    /// may have moved or closed the covering window meanwhile, and §3.0.3 says
    /// the collapse goes to Docked when the overlap is gone.
    private func collapseTarget() -> PresenceState {
        overlap.evaluateNow() ? .shim : .docked
    }

    private func overlapChanged(_ overlapping: Bool) {
        guard state != .revealed else { return }
        transition(to: overlapping ? .shim : .docked)
    }

    // MARK: Pointer input

    /// Passive global monitor — it observes, never consumes.
    private func installGlobalMouseMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.globalMouseMoved(NSEvent.mouseLocation)
            }
        }
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.presence.info("Screen parameters changed — re-centering")
                self?.rebuild()
            }
        }
    }

    private func globalMouseMoved(_ point: NSPoint) {
        guard moduleCount > 0, let screen = currentScreen else { return }

        if state == .revealed {
            // The pill can slide out under a pointer that never crosses its
            // boundary, so its tracking area may never report an enter *or* an
            // exit. Watch the union directly: outside it, arm the collapse.
            revealedPointerMoved(point)
            return
        }
        guard state == .shim else {
            // Docked: the pill's own tracking area is authoritative.
            return
        }
        let band = bodyFrame(on: screen)
        let visible = screen.visibleFrame
        let hotZone = NSRect(
            x: visible.maxX - Self.hotZoneWidth,
            y: band.minY,
            width: Self.hotZoneWidth,
            height: band.height
        )

        if hotZone.contains(point) {
            guard dwellWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwellWorkItem = nil
                guard self.state == .shim else { return }
                self.transition(to: .revealed)
            }
            dwellWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: item)
        } else {
            dwellWorkItem?.cancel()
            dwellWorkItem = nil
        }
    }

    /// While revealed, the union of pill and popover is the hover region. The
    /// tracking areas alone are not enough: the pill animates in under a
    /// stationary pointer, so an enter may never fire and therefore an exit
    /// never will either (§3.0.3 requires the collapse regardless).
    private func revealedPointerMoved(_ point: NSPoint) {
        let inUnion = unionContains(point)
        if inUnion {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            return
        }
        // Outside the union: the tracking area may still believe the pointer is
        // inside (it never saw a crossing), so clear the flags before arming.
        if pointerInPill { pointerInPill = false }
        if pointerInPopover { pointerInPopover = false }
        guard collapseWorkItem == nil else { return }
        scheduleUnionExit()
    }

    /// Pill ∪ popover, in screen coordinates. Only counts panels on screen.
    private func unionContains(_ point: NSPoint) -> Bool {
        if pill.isVisible, pill.frame.contains(point) { return true }
        if popover.isVisible, popover.frame.contains(point) { return true }
        return false
    }

    private func pillPointer(inside: Bool) {
        pointerInPill = inside
        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            popoverCloseWorkItem?.cancel()
            popoverCloseWorkItem = nil
        } else {
            hoveredIndex = nil
            model.hoveredProviderID = nil
            popoverOpenWorkItem?.cancel()
            popoverOpenWorkItem = nil
            scheduleUnionExit()
        }
    }

    private func popoverPointer(inside: Bool) {
        pointerInPopover = inside
        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            popoverCloseWorkItem?.cancel()
            popoverCloseWorkItem = nil
        } else {
            scheduleUnionExit()
        }
    }

    /// The pill and the popover form one hover region; leaving it starts both
    /// the popover's 200ms grace and (from revealed) the 500ms collapse.
    private func scheduleUnionExit() {
        guard !pointerInPill, !pointerInPopover else { return }

        if !popover.isPinned, popover.targetProviderID != nil {
            popoverCloseWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.popoverCloseWorkItem = nil
                guard !self.pointerInPill, !self.pointerInPopover, !self.popover.isPinned else { return }
                self.popover.dismiss()
            }
            popoverCloseWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverExitGrace, execute: item)
        }

        guard state == .revealed else { return }
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            guard !self.pointerInPill, !self.pointerInPopover, self.state == .revealed else { return }
            if self.popover.isPinned { return }
            self.transition(to: self.collapseTarget())
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealCollapse, execute: item)
    }

    private func pillPointerMoved(to point: NSPoint) {
        // A move inside the view is proof of presence. The pill can animate out
        // from under a stationary pointer, in which case no `mouseEntered` ever
        // fires and the deferred open below would otherwise never pass its
        // `pointerInPill` guard (§3.2's 300ms hover-to-popover).
        if !pointerInPill {
            pointerInPill = true
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            popoverCloseWorkItem?.cancel()
            popoverCloseWorkItem = nil
        }

        let index = PillMetrics.moduleIndex(atY: point.y, count: moduleCount)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        model.hoveredProviderID = index.flatMap { visibleSlots[safe: $0]?.id }

        popoverOpenWorkItem?.cancel()
        popoverOpenWorkItem = nil

        guard let index, let slot = visibleSlots[safe: index] else {
            if !popover.isPinned { scheduleUnionExit() }
            return
        }

        // Retarget an already-open popover immediately; otherwise wait out the delay.
        if popover.targetProviderID != nil {
            presentPopover(for: slot, index: index, pinned: popover.isPinned)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.popoverOpenWorkItem = nil
            guard self.hoveredIndex == index, self.pointerInPill else { return }
            self.presentPopover(for: slot, index: index, pinned: false)
        }
        popoverOpenWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverOpenDelay, execute: item)
    }

    private func pillClicked(at point: NSPoint) {
        guard let index = PillMetrics.moduleIndex(atY: point.y, count: moduleCount),
              let slot = visibleSlots[safe: index] else { return }

        // Click cancels the hover delay and opens immediately; a second click on
        // the same ring closes.
        popoverOpenWorkItem?.cancel()
        popoverOpenWorkItem = nil

        if popover.isPinned, popover.targetProviderID == slot.id {
            closePopover()
            return
        }
        presentPopover(for: slot, index: index, pinned: true)
    }

    private func presentPopover(for slot: ProviderSlot, index: Int, pinned: Bool) {
        guard let screen = currentScreen else { return }
        let frame = pill.frame
        // Ring centers are laid out from the top of the pill body downward.
        let ringY = frame.maxY - PillMetrics.ringCenterY(index: index)
        popover.show(
            slot: slot,
            ringCenter: NSPoint(x: frame.minX, y: ringY),
            pillLeftEdge: frame.minX,
            on: screen,
            pinned: pinned
        )
    }

    private func closePopover() {
        popoverOpenWorkItem?.cancel()
        popoverOpenWorkItem = nil
        popoverCloseWorkItem?.cancel()
        popoverCloseWorkItem = nil
        popover.dismiss()
        // The panel is gone, so its tracking area will never report an exit.
        pointerInPopover = false
        if state == .revealed, !pointerInPill { scheduleUnionExit() }
    }

    private func cancelAllTimers() {
        dwellWorkItem?.cancel()
        collapseWorkItem?.cancel()
        popoverOpenWorkItem?.cancel()
        popoverCloseWorkItem?.cancel()
        dwellWorkItem = nil
        collapseWorkItem = nil
        popoverOpenWorkItem = nil
        popoverCloseWorkItem = nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
