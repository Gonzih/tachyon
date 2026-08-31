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
        collectionBehavior = OverlayPanelPolicy.collectionBehavior
        isFloatingPanel = OverlayPanelPolicy.isFloatingPanel
        hidesOnDeactivate = OverlayPanelPolicy.hidesOnDeactivate
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
                let idle = dark
                    ? NSColor.white.withAlphaComponent(0.25)
                    : NSColor.black.withAlphaComponent(0.22)
                return ShimView.Segment(color: idle, alpha: 0.6, isPaceHot: false)
            }
            return ShimView.Segment(
                color: UsageColor.nsBand(percent, darkAppearance: dark),
                alpha: slot.displaysStale() ? 0.32 : 0.6,
                isPaceHot: slot.ringIsPaceHot
            )
        }
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

    /// Layer-per-segment so a pace-hot segment can pulse via a repeating Core
    /// Animation — the render server does the breathing, the app spends zero
    /// CPU per frame. Segments are laid out top to bottom like the rings.
    private final class ShimView: NSView {
        struct Segment {
            let color: NSColor
            let alpha: CGFloat
            let isPaceHot: Bool
        }

        var segments: [Segment] = [] {
            didSet { needsLayout = true }
        }

        private var segmentLayers: [CALayer] = []
        private static let pulseKey = "tachyon.pacePulse"

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()

            while segmentLayers.count < segments.count {
                let segmentLayer = CALayer()
                layer?.addSublayer(segmentLayer)
                segmentLayers.append(segmentLayer)
            }
            while segmentLayers.count > segments.count {
                segmentLayers.removeLast().removeFromSuperlayer()
            }
            guard !segments.isEmpty else { return }

            let count = CGFloat(segments.count)
            let totalGap = ShimPanel.gap * (count - 1)
            let segmentHeight = (bounds.height - totalGap) / count
            guard segmentHeight > 0 else { return }

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for (index, segment) in segments.enumerated() {
                let segmentLayer = segmentLayers[index]
                // Layer space is bottom-left origin; index 0 belongs at the top.
                let top = CGFloat(index) * (segmentHeight + ShimPanel.gap)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                segmentLayer.frame = NSRect(
                    x: 0, y: bounds.height - top - segmentHeight,
                    width: bounds.width, height: segmentHeight
                )
                segmentLayer.cornerRadius = bounds.width / 2
                segmentLayer.backgroundColor = segment.color.withAlphaComponent(segment.alpha).cgColor
                CATransaction.commit()

                if segment.isPaceHot, !reduceMotion {
                    if segmentLayer.animation(forKey: Self.pulseKey) == nil {
                        let pulse = CABasicAnimation(keyPath: "opacity")
                        pulse.fromValue = 1.0
                        pulse.toValue = 0.35
                        pulse.duration = 0.9
                        pulse.autoreverses = true
                        pulse.repeatCount = .infinity
                        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        segmentLayer.add(pulse, forKey: Self.pulseKey)
                    }
                } else {
                    segmentLayer.removeAnimation(forKey: Self.pulseKey)
                }
            }
        }
    }
}
