import AppKit
import SwiftUI

/// One policy for every Tachyon surface that may be ordered independently.
///
/// These flags are deliberately verbose and non-redundant. `canJoinAllSpaces`
/// covers the user's Spaces, `canJoinAllApplications` lets a floating overlay
/// follow another app's window set (including its full-screen Space), and
/// `fullScreenAuxiliary` keeps AppKit from stranding the panels during that
/// handoff. The controller still orders every surface out while fullscreen is
/// active. Removing any one of these flags can strand a panel in the Space
/// where it was first ordered.
enum OverlayPanelPolicy {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .stationary,
        .fullScreenAuxiliary,
    ]

    /// NSPanel defaults this to true. A Space handoff deactivates Tachyon, so
    /// every independently ordered overlay must override that default or
    /// AppKit removes it despite its cross-Space collection behavior. Keep the
    /// policy here rather than relying on each new surface to remember it.
    static let hidesOnDeactivate = false

    /// AppKit only treats an `NSPanel` as a persistent utility surface when
    /// this is set explicitly. In an accessory app that distinction matters:
    /// a non-floating panel can keep its global `isVisible` bit while its
    /// WindowServer representation remains attached to the Space where it was
    /// first ordered.
    static let isFloatingPanel = true
}

/// Borderless, non-activating panel. Never takes focus, floats at status-bar
/// level so a revealed pill draws over ordinary windows, and follows the user
/// across spaces and full-screen apps.
@MainActor
final class PillPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = OverlayPanelPolicy.collectionBehavior
        isFloatingPanel = OverlayPanelPolicy.isFloatingPanel
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = OverlayPanelPolicy.hidesOnDeactivate
        animationBehavior = .none
    }

    /// Focus would yank the user out of whatever they are typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts a SwiftUI view and reports pointer activity through AppKit tracking
/// areas.
///
/// SwiftUI's `.onHover` never fires inside a non-activating accessory panel, so
/// tracking areas are the only path. `acceptsFirstMouse` keeps the very first
/// click from being swallowed as an activation click.
@MainActor
final class TrackingHostView<Content: View>: NSView {
    private let hosting: NSHostingView<Content>

    var onEnter: (() -> Void)?
    /// Point in this view's coordinate space, y measured from the top.
    var onMove: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var rootView: Content {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    /// Top-left origin, matching the SwiftUI layout the caller reasons about.
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    /// Without this the first click on a non-activating panel is consumed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
