import AppKit

/// The 5pt color sliver left behind when the pill hides itself.
///
/// One rounded segment per visible provider, filled with that provider's usage
/// color at 60% opacity, 2pt gaps, total height matching the pill. A red sliver
/// at the corner of your eye is the whole point; everything else is silent.
@MainActor
final class ShimPanel: NSPanel {
    static let width: CGFloat = 5
    private static let gap: CGFloat = 2

    private let shimView = ShimView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // The shim is decoration: the 12pt hot zone handles reveal, so the panel
        // itself must never eat clicks meant for the window underneath.
        ignoresMouseEvents = true
        animationBehavior = .none
        contentView = shimView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Segment colors, top to bottom, in the same order as the pill's rings.
    func update(slots: [ProviderSlot]) {
        let dark = shimView.effectiveAppearance.isDarkTheme
        shimView.segments = slots.map { slot in
            guard let percent = slot.ringBandPercent ?? slot.ringPercent else {
                return dark
                    ? NSColor.white.withAlphaComponent(0.25)
                    : NSColor.black.withAlphaComponent(0.22)
            }
            return UsageColor.nsBand(percent, darkAppearance: dark)
        }
        shimView.needsDisplay = true
    }

    /// Places the shim flush to the right edge, matching the pill's band.
    func position(on screen: NSScreen, moduleCount: Int) {
        let height = PillMetrics.height(moduleCount: moduleCount)
        let frame = screen.visibleFrame
        setFrame(
            NSRect(
                x: frame.maxX - Self.width,
                y: frame.midY - height / 2,
                width: Self.width,
                height: height
            ),
            display: true
        )
    }

    private final class ShimView: NSView {
        var segments: [NSColor] = []

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !segments.isEmpty else { return }
            let count = CGFloat(segments.count)
            let totalGap = ShimPanel.gap * (count - 1)
            let segmentHeight = (bounds.height - totalGap) / count
            guard segmentHeight > 0 else { return }

            for (index, color) in segments.enumerated() {
                let y = CGFloat(index) * (segmentHeight + ShimPanel.gap)
                let rect = NSRect(x: 0, y: y, width: bounds.width, height: segmentHeight)
                let path = NSBezierPath(
                    roundedRect: rect,
                    xRadius: bounds.width / 2,
                    yRadius: bounds.width / 2
                )
                color.withAlphaComponent(0.6).setFill()
                path.fill()
            }
        }
    }
}
