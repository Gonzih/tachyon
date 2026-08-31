import AppKit
import SwiftUI

/// Owns the pill, shim and popover, and runs the docked / shim / suppressed →
/// revealed state machine.
///
/// Timing constants are all distinct on purpose, so a stall is attributable:
/// overlap hysteresis 300ms (in `OverlapMonitor`), hover dwell 150ms, reveal
/// collapse 500ms, popover open 300ms, popover exit grace 200ms.
@MainActor
final class EdgeController {
    /// The app layer supplies the context menu (same one as the status item).
    /// Right-click anywhere on the pill: straight to Settings, focused on the
    /// clicked provider's pane when the click landed on a ring.
    var onPillRightClick: ((String?) -> Void)?

    enum PresenceState: Equatable {
        case docked
        case shim
        /// A full-screen foreign window covers this display. Both visible edge
        /// surfaces are absent, but the invisible hover band remains armed.
        case suppressed
        case revealed

        var keepsPillOffEdge: Bool {
            self == .shim || self == .suppressed
        }
    }

    private struct ScreenContext: Equatable {
        let displayID: CGDirectDisplayID?
        let frame: NSRect
    }

    // Timings (seconds).
    private static let hoverDwell: TimeInterval = 0.15
    private static let revealCollapse: TimeInterval = 0.5
    private static let popoverOpenDelay: TimeInterval = 0.3
    private static let popoverExitGrace: TimeInterval = 0.2
    /// Width of the edge strip that arms the reveal.
    private static let hotZoneWidth: CGFloat = 12
    private static let slideOutDuration: TimeInterval = 0.18
    private static let slideInDuration: TimeInterval = 0.22

    private(set) var state: PresenceState = .docked

    private let model: UsageModel
    private let pill: PillPanel
    private let shim = ShimPanel()
    private let popover = PopoverPanel()
    private let overlap = OverlapMonitor()
    private var hostView: TrackingHostView<PillView>

    private var globalMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    private var dwellWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var popoverOpenWorkItem: DispatchWorkItem?
    private var popoverCloseWorkItem: DispatchWorkItem?

    /// Delayed interaction work is valid only for the provider/display surface
    /// that scheduled it. Animation completions additionally belong to one
    /// exact state transition. These counters prevent hidden or stopped panels
    /// from being resurrected by an old closure.
    private var surfaceGeneration: UInt = 0
    private var transitionGeneration: UInt = 0
    private var renderedProviderIDs: [String] = []
    private var renderedScreenContext: ScreenContext?

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
            let point = self.hostView.convert(event.locationInWindow, from: nil)
            let id = PillMetrics.moduleIndex(atY: point.y, count: self.moduleCount)
                .flatMap { self.visibleSlots[safe: $0]?.id }
            self.onPillRightClick?(id)
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
            guard let self, self.moduleCount > 0, let screen = self.currentScreen else { return nil }
            return (self.bodyFrame(on: screen), screen)
        }
        overlap.onChange = { [weak self] obstruction in self?.obstructionChanged(obstruction) }
    }

    // MARK: Lifecycle

    func start() {
        rebuild()
        installGlobalMouseMonitor()
        installScreenObserver()
        overlap.start()
    }

    func stop() {
        surfaceGeneration &+= 1
        transitionGeneration &+= 1
        overlap.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        cancelAllTimers()
        popover.dismiss()
        pill.orderOut(nil)
        shim.orderOut(nil)
        clearPointerState()
        state = .docked
        renderedProviderIDs = []
        renderedScreenContext = nil
    }

    /// Re-reads the model and repositions everything. Cheap enough to call on
    /// every snapshot.
    func rebuild() {
        let slots = visibleSlots
        let providerIDs = slots.map(\.id)
        let providersChanged = providerIDs != renderedProviderIDs
        renderedProviderIDs = providerIDs
        hostView.rootView = PillView(slots: slots)
        shim.update(slots: slots)

        guard !slots.isEmpty, let screen = currentScreen else {
            // Nothing to show: the status item is the way back.
            hideUnavailableSurfaces()
            return
        }

        let screenContext = ScreenContext(displayID: screen.displayID, frame: screen.frame)
        let screenChanged = screenContext != renderedScreenContext
        renderedScreenContext = screenContext
        let surfaceChanged = providersChanged || screenChanged
        if surfaceChanged {
            invalidateSurfaceWork(clearPointerState: screenChanged)
            adoptCurrentObstructionIfIdle()
        }

        shim.position(on: screen, moduleCount: slots.count)
        applyFrame(for: state, on: screen, animated: false)
        placePanels(for: state)

        // Keep an open popover attached to the same visible ring. Re-presenting
        // also remeasures row-count changes and fixes the tail after reordering.
        if let id = popover.targetProviderID {
            if let index = slots.firstIndex(where: { $0.id == id }) {
                presentPopover(for: slots[index], index: index, pinned: popover.isPinned)
            } else {
                closePopover()
            }
        }
        if surfaceChanged { reconcilePointerAfterRebuild() }
        overlap.poke()
    }

    private func hideUnavailableSurfaces() {
        let wasRevealed = state == .revealed
        surfaceGeneration &+= 1
        transitionGeneration &+= 1
        cancelAllTimers()
        popover.dismiss()
        pill.orderOut(nil)
        shim.orderOut(nil)
        clearPointerState()
        state = .docked
        renderedScreenContext = nil
        if wasRevealed { overlap.resume() }
    }

    private func invalidateSurfaceWork(clearPointerState shouldClearPointers: Bool) {
        surfaceGeneration &+= 1
        transitionGeneration &+= 1
        cancelAllTimers()
        if shouldClearPointers {
            pointerInPill = false
            pointerInPopover = false
        }
    }

    /// Provider count and display selection both change the geometry being
    /// classified. Read synchronously before placing panels so a newly selected
    /// fullscreen display never inherits another display's presentation.
    private func adoptCurrentObstructionIfIdle() {
        let observed = overlap.evaluateNow()
        guard !isInteracting else { return }
        let next = Self.restingState(for: observed)
        guard next != state else { return }
        let previous = state
        state = next
        Log.presence.debug("State \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public) (fresh context)")
        if previous == .revealed { overlap.resume() }
    }

    private func clearPointerState() {
        pointerInPill = false
        pointerInPopover = false
        hoveredIndex = nil
        model.hoveredProviderID = nil
    }

    /// Tracking areas do not guarantee enter/exit events when a panel moves to
    /// another display or changes height under a stationary pointer. Rebuild
    /// the flags from actual panel geometry, then resume the normal exit path.
    private func reconcilePointerAfterRebuild() {
        let point = NSEvent.mouseLocation
        pointerInPill = pill.isVisible && pill.frame.contains(point)
        pointerInPopover = popover.isVisible && popover.frame.contains(point)
        if state == .revealed {
            revealedPointerMoved(point)
        } else if !pointerInPill, !pointerInPopover {
            scheduleUnionExit()
        }
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
        let target = state.keepsPillOffEdge ? hiddenFrame(on: screen) : dockedFrame(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            pill.setFrame(target, display: true)
            return
        }
        let duration = state.keepsPillOffEdge ? Self.slideOutDuration : Self.slideInDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // Departures accelerate away, arrivals decelerate in — and the
            // slide is a pure translation, so the content never needs to
            // redisplay mid-flight (display: false). The window server moves
            // the layer and its shadow wholesale; nothing re-renders per frame.
            context.timingFunction = CAMediaTimingFunction(
                name: state.keepsPillOffEdge ? .easeIn : .easeOut
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
        case .suppressed:
            pill.orderOut(nil)
            shim.orderOut(nil)
        }
    }

    // MARK: State machine

    private func transition(to next: PresenceState) {
        guard next != state, moduleCount > 0, let screen = currentScreen else { return }
        let previous = state
        transitionGeneration &+= 1
        let generation = transitionGeneration
        state = next
        Log.presence.debug("State \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)")

        switch next {
        case .shim:
            enterOffEdgeState(.shim, from: previous, on: screen, generation: generation)

        case .suppressed:
            enterOffEdgeState(.suppressed, from: previous, on: screen, generation: generation)

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
                guard let self,
                      self.transitionGeneration == generation,
                      self.state == .revealed,
                      self.moduleCount > 0
                else { return }
                self.revealedPointerMoved(NSEvent.mouseLocation)
            }

        case .docked:
            overlap.resume()
            pill.orderFrontRegardless()
            if previous.keepsPillOffEdge {
                // Slide in from off-screen; keep the shim up until the pill
                // lands so the edge is never bare mid-transition.
                pill.setFrame(hiddenFrame(on: screen), display: false)
                applyFrame(for: .docked, on: screen, animated: true)
                if previous == .suppressed { shim.orderOut(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideInDuration) { [weak self] in
                    guard let self,
                          self.transitionGeneration == generation,
                          self.state == .docked,
                          self.moduleCount > 0
                    else { return }
                    self.shim.orderOut(nil)
                }
            } else {
                shim.orderOut(nil)
                applyFrame(for: .docked, on: screen, animated: previous == .revealed)
            }
        }
    }

    /// Moves the pill to its shared off-edge frame, then either exposes the
    /// useful overlap shim or leaves the edge visually empty for full screen.
    private func enterOffEdgeState(
        _ next: PresenceState,
        from previous: PresenceState,
        on screen: NSScreen,
        generation: UInt
    ) {
        let showsShim = next == .shim
        shim.position(on: screen, moduleCount: moduleCount)
        popover.dismiss()
        pointerInPopover = false
        overlap.resume()

        if previous.keepsPillOffEdge {
            pill.setFrame(hiddenFrame(on: screen), display: false)
            pill.orderOut(nil)
            setShimVisible(showsShim)
            return
        }

        if !showsShim { shim.orderOut(nil) }
        applyFrame(for: next, on: screen, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOutDuration + 0.03) { [weak self] in
            guard let self,
                  self.transitionGeneration == generation,
                  self.state == next,
                  self.moduleCount > 0
            else { return }
            self.pill.orderOut(nil)
            self.setShimVisible(showsShim)
        }
    }

    private func setShimVisible(_ visible: Bool) {
        if visible {
            shim.orderFrontRegardless()
        } else {
            shim.orderOut(nil)
        }
    }

    /// Where a collapse from `.revealed` should land.
    ///
    /// The monitor is paused while revealed, so its published classification is
    /// frozen. Re-read it: the user may have moved, resized, or closed the
    /// covering window, and §3.0 says collapse follows current reality.
    private func collapseTarget() -> PresenceState {
        Self.restingState(for: overlap.evaluateNow())
    }

    static func restingState(for obstruction: WindowObstruction) -> PresenceState {
        switch obstruction {
        case .none: .docked
        case .overlap: .shim
        case .fullScreen: .suppressed
        }
    }

    /// Automatic window changes never interrupt an active Tachyon interaction.
    /// Returning nil means "retain the current presentation until interaction
    /// ends," at which point the latest obstruction is reconciled.
    static func automaticTarget(
        for obstruction: WindowObstruction,
        from state: PresenceState,
        interactionActive: Bool
    ) -> PresenceState? {
        guard state != .revealed, !interactionActive else { return nil }
        return restingState(for: obstruction)
    }

    private var isInteracting: Bool {
        pointerInPill || pointerInPopover || popover.targetProviderID != nil
    }

    private func obstructionChanged(_ obstruction: WindowObstruction) {
        // Never pull an active hover or pinned detail view out from under the
        // pointer. The monitor retains the newest observation; interaction end
        // reconciles it even when that same observation emits no second event.
        guard let target = Self.automaticTarget(
            for: obstruction,
            from: state,
            interactionActive: isInteracting
        ) else { return }
        transition(to: target)
    }

    private func settleAfterInteraction() {
        guard let target = Self.automaticTarget(
            for: overlap.obstruction,
            from: state,
            interactionActive: isInteracting
        ) else { return }
        transition(to: target)
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
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.presence.info("Active Space changed — reasserting overlay")
                // A Space switch does not change NSScreen geometry, so the
                // ordinary screen cache would call this an unchanged surface.
                // Force one fresh obstruction read before any panel is ordered;
                // this prevents both a flash over full-screen content and a
                // panel remaining affiliated with the Space it just left.
                self.renderedScreenContext = nil
                self.rebuild()
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
        guard state.keepsPillOffEdge else {
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
            let generation = surfaceGeneration
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwellWorkItem = nil
                guard self.surfaceGeneration == generation,
                      self.state.keepsPillOffEdge,
                      self.moduleCount > 0
                else { return }
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

        let awaitingPopoverDismissal = schedulePopoverDismissalIfNeeded()
        guard state == .revealed else {
            if !awaitingPopoverDismissal { settleAfterInteraction() }
            return
        }
        collapseWorkItem?.cancel()
        let generation = surfaceGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            guard self.surfaceGeneration == generation,
                  !self.pointerInPill,
                  !self.pointerInPopover,
                  self.state == .revealed,
                  self.moduleCount > 0
            else { return }
            if self.popover.isPinned { return }
            self.transition(to: self.collapseTarget())
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealCollapse, execute: item)
    }

    @discardableResult
    private func schedulePopoverDismissalIfNeeded() -> Bool {
        guard !popover.isPinned, popover.targetProviderID != nil else { return false }
        popoverCloseWorkItem?.cancel()
        let generation = surfaceGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.popoverCloseWorkItem = nil
            guard self.surfaceGeneration == generation,
                  !self.pointerInPill,
                  !self.pointerInPopover,
                  !self.popover.isPinned
            else { return }
            self.popover.dismiss()
            self.settleAfterInteraction()
        }
        popoverCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverExitGrace, execute: item)
        return true
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

        let providerID = slot.id
        let generation = surfaceGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.popoverOpenWorkItem = nil
            guard self.surfaceGeneration == generation,
                  self.hoveredIndex == index,
                  self.pointerInPill,
                  let currentSlot = self.visibleSlots[safe: index],
                  currentSlot.id == providerID
            else { return }
            self.presentPopover(for: currentSlot, index: index, pinned: false)
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
        if state == .revealed, !pointerInPill {
            scheduleUnionExit()
        } else {
            settleAfterInteraction()
        }
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
