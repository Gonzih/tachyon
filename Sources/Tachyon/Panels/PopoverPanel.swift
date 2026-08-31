import AppKit
import SwiftUI

/// The detail popover: a borderless HUD panel with a right-pointing tail,
/// positioned to the left of the pill and clamped to the visible frame.
///
/// Deliberately not `NSPopover`: an `NSPopover` insists on an activating host
/// window, which would steal focus from whatever the user is doing.
@MainActor
final class PopoverPanel: NSPanel {
    /// Horizontal gap between the pill's left edge and the popover's tail tip.
    private static let tailWidth: CGFloat = 8
    private static let tailHeight: CGFloat = 16
    private static let edgeInset: CGFloat = 8

    private let container = PopoverContainerView()

    /// Which provider the popover is currently showing.
    private(set) var targetProviderID: String?
    /// Click-opened popovers stay until dismissed explicitly.
    private(set) var isPinned = false

    var onPointerInside: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    /// Frames that must not count as "click-away" — the pill above all. Without
    /// it, clicking a pinned ring dismisses here first (a local monitor runs
    /// before the window sees the event), so the ring's own click handler then
    /// finds no pinned popover and re-opens it: §3.2's "second click on the same
    /// ring dismisses" would be unreachable.
    var excludedFrames: (() -> [NSRect])?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DetailView.width + Self.tailWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = OverlayPanelPolicy.collectionBehavior
        animationBehavior = .none
        contentView = container
        container.onEnter = { [weak self] in self?.onPointerInside?(true) }
        container.onExit = { [weak self] in self?.onPointerInside?(false) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Showing

    /// Shows (or retargets) the popover for `slot`.
    ///
    /// `ringCenter` is the ring's center in screen coordinates; `pillLeftEdge`
    /// is the x the tail tip should touch.
    func show(
        slot: ProviderSlot,
        ringCenter: NSPoint,
        pillLeftEdge: CGFloat,
        on screen: NSScreen,
        pinned: Bool
    ) {
        targetProviderID = slot.id
        if pinned { isPinned = true }

        let content = DetailView(slot: slot)
        let size = Self.measure(content)
        let bodyHeight = max(size.height, Self.tailHeight + 8)
        let totalWidth = DetailView.width + Self.tailWidth

        // Prefer centering the body on the ring; clamp inside the visible frame.
        let visible = screen.visibleFrame
        var originY = ringCenter.y - bodyHeight / 2
        originY = min(max(originY, visible.minY + Self.edgeInset), visible.maxY - bodyHeight - Self.edgeInset)
        let originX = pillLeftEdge - totalWidth

        // Tail y is measured from the top of the panel down to the ring.
        let tailCenterFromTop = (originY + bodyHeight) - ringCenter.y
        container.tailCenterFromTop = min(
            max(tailCenterFromTop, Self.tailHeight),
            bodyHeight - Self.tailHeight
        )
        container.tailWidth = Self.tailWidth
        container.tailHeight = Self.tailHeight
        container.setContent(content, bodyWidth: DetailView.width)

        setFrame(
            NSRect(x: originX, y: originY, width: totalWidth, height: bodyHeight),
            display: true
        )
        if !isVisible {
            // Soft entrance: fade rather than pop. Skipped under Reduce Motion.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                alphaValue = 1
            } else {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().alphaValue = 1
                }
            }
            orderFrontRegardless()
        }
        installMonitors()
    }

    func dismiss() {
        guard isVisible || targetProviderID != nil else { return }
        removeMonitors()
        targetProviderID = nil
        isPinned = false
        guard isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil)
            return
        }
        // Fade out, then order out — unless a new present() reclaimed the
        // panel mid-fade (targetProviderID becomes non-nil again).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit invokes this on the main thread; the closure just isn't
            // typed that way.
            MainActor.assumeIsolated {
                if self.targetProviderID == nil {
                    self.orderOut(nil)
                }
                self.alphaValue = 1
            }
        })
    }

    private static func measure(_ view: DetailView) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        return CGSize(width: DetailView.width, height: max(fitting.height, 60))
    }

    // MARK: Esc / click-away

    /// A borderless panel can never become key, so `keyDown` never reaches the
    /// responder chain. Monitors are the only way to see Esc and outside clicks
    /// — and they must be torn down on dismissal or they fire forever.
    private func installMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // The monitor closure is nonisolated, but AppKit only ever calls it
            // on the main thread; `assumeIsolated` states that contract.
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .keyDown {
                    // 53 = Esc.
                    guard event.keyCode == 53 else { return false }
                    self.requestDismiss()
                    return true
                }
                if !self.frameContains(NSEvent.mouseLocation) {
                    self.requestDismiss()
                }
                return false
            }
            return swallow ? nil : event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.frameContains(NSEvent.mouseLocation) {
                    self.requestDismiss()
                }
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// True when the point is inside the popover or any frame the owner has
    /// excluded (the pill), i.e. when the click is *not* a click-away.
    private func frameContains(_ point: NSPoint) -> Bool {
        if frame.insetBy(dx: -2, dy: -2).contains(point) { return true }
        for excluded in excludedFrames?() ?? [] where excluded.contains(point) {
            return true
        }
        return false
    }

    private func requestDismiss() {
        onDismiss?()
    }
}

/// Draws the HUD background plus tail, and hosts the SwiftUI content inset from
/// the tail side.
@MainActor
private final class PopoverContainerView: NSView {
    var tailCenterFromTop: CGFloat = 30
    var tailWidth: CGFloat = 8
    var tailHeight: CGFloat = 16

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var hosting: NSHostingView<DetailView>?

    override var isFlipped: Bool { true }

    func setContent(_ view: DetailView, bodyWidth: CGFloat) {
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
                hosting.widthAnchor.constraint(equalToConstant: bodyWidth),
            ])
            self.hosting = hosting
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = DetailView.cornerRadius
        let body = NSRect(
            x: 0, y: 0,
            width: max(0, bounds.width - tailWidth),
            height: bounds.height
        )

        // One continuous outline — body and tail as a single boundary, so the
        // light theme's stroke never draws the body edge across the tail base.
        let center = min(max(tailCenterFromTop, radius + tailHeight / 2), bounds.height - radius - tailHeight / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        // Bottom edge → bottom-right corner → up the right edge to the tail.
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: center - tailHeight / 2))
        path.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: center))
        path.addLine(to: CGPoint(x: body.maxX, y: center + tailHeight / 2))
        // Rest of the right edge → top-right → top → top-left → left → close.
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()

        let dark = effectiveAppearance.isDarkTheme
        context.addPath(path)
        context.setFillColor(
            dark
                ? NSColor.black.withAlphaComponent(0.94).cgColor
                : NSColor(white: 0.98, alpha: 0.97).cgColor
        )
        context.fillPath()

        if !dark {
            context.addPath(path)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
