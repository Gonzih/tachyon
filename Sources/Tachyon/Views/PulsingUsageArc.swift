import AppKit
import SwiftUI

/// The ring's colored usage arc, backed by a `CAShapeLayer` rather than a
/// SwiftUI repeat-forever animation. Pace-hot rings need to breathe, but that
/// visual cue must not invalidate the entire pill view at display refresh rate.
/// Core Animation owns the per-frame opacity interpolation in its render
/// server; SwiftUI only updates this view when the reading or its pace changes.
struct PulsingUsageArc: NSViewRepresentable {
    let percent: Double
    let color: NSColor
    let isPaceHot: Bool

    func makeNSView(context: Context) -> PaceArcView {
        let view = PaceArcView(frame: .zero)
        view.render(percent: percent, color: color, isPaceHot: isPaceHot, animated: false)
        return view
    }

    func updateNSView(_ view: PaceArcView, context: Context) {
        view.render(percent: percent, color: color, isPaceHot: isPaceHot, animated: true)
    }
}

/// AppKit implementation kept internal so XCTest can verify the layer policy
/// without relying on timing-sensitive SwiftUI rendering snapshots.
@MainActor
final class PaceArcView: NSView {
    static let pacePulseKey = PacePulseLayer.animationKey
    private static let strokeEndKey = "tachyon.usageArcStrokeEnd"
    private static let lineWidth: CGFloat = PillMetrics.ringStroke
    private static let minimumVisibleFraction: CGFloat = 0.0001

    private let arcLayer = CAShapeLayer()
    private var hasRendered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        arcLayer.fillColor = NSColor.clear.cgColor
        arcLayer.lineWidth = Self.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        // `CGPath(ellipseIn:)` starts at three o'clock. Match SwiftUI's
        // `Circle().rotationEffect(-90)` so progress starts at twelve.
        arcLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        layer?.addSublayer(arcLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let circle = bounds.insetBy(dx: inset, dy: inset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.frame = bounds
        arcLayer.path = circle.isEmpty ? nil : CGPath(ellipseIn: circle, transform: nil)
        CATransaction.commit()
    }

    func render(percent: Double, color: NSColor, isPaceHot: Bool, animated: Bool) {
        let nextFraction = Self.fraction(for: percent)
        let previousFraction = arcLayer.presentation()?.strokeEnd ?? arcLayer.strokeEnd

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.strokeColor = color.cgColor
        arcLayer.strokeEnd = nextFraction
        CATransaction.commit()

        if animated, hasRendered, abs(previousFraction - nextFraction) > 0.0001 {
            let progress = CABasicAnimation(keyPath: "strokeEnd")
            progress.fromValue = previousFraction
            progress.toValue = nextFraction
            progress.duration = 0.4
            progress.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arcLayer.add(progress, forKey: Self.strokeEndKey)
        }

        PacePulseLayer.update(arcLayer, isPaceHot: isPaceHot)
        hasRendered = true
    }

    private static func fraction(for percent: Double) -> CGFloat {
        guard percent.isFinite else { return minimumVisibleFraction }
        return max(minimumVisibleFraction, min(1, CGFloat(percent / 100)))
    }
}

// MARK: - Progress bar

/// The popover's pace-hot bar uses the same render-server pulse as its ring.
/// Its width remains owned by SwiftUI's layout; only per-frame opacity leaves
/// SwiftUI, so the bar keeps its exact existing geometry and colors.
struct PulsingUsageBar: NSViewRepresentable {
    let color: NSColor
    let isPaceHot: Bool

    func makeNSView(context: Context) -> PaceBarView {
        let view = PaceBarView(frame: .zero)
        view.render(color: color, isPaceHot: isPaceHot)
        return view
    }

    func updateNSView(_ view: PaceBarView, context: Context) {
        view.render(color: color, isPaceHot: isPaceHot)
    }
}

@MainActor
final class PaceBarView: NSView {
    private let fillLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        fillLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    func render(color: NSColor, isPaceHot: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = color.cgColor
        CATransaction.commit()
        PacePulseLayer.update(fillLayer, isPaceHot: isPaceHot)
    }
}

/// Centralizes the exact 0.9-second breath and 0.2-second settle shared by a
/// pace-hot ring and its detail bar. This is intentionally Core Animation:
/// changing an opacity in the render tree costs no SwiftUI view recomputation
/// each frame, while retaining the same visual urgency.
@MainActor
enum PacePulseLayer {
    static let animationKey = "tachyon.pacePulse"
    private static let exitKey = "tachyon.pacePulseExit"

    static func update(_ layer: CALayer, isPaceHot: Bool) {
        if isPaceHot {
            layer.removeAnimation(forKey: exitKey)
            guard layer.animation(forKey: animationKey) == nil else { return }
            setOpacity(1, on: layer)

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.4
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: animationKey)
            return
        }

        guard layer.animation(forKey: animationKey) != nil else {
            setOpacity(1, on: layer)
            return
        }

        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: animationKey)
        setOpacity(1, on: layer)
        guard fromOpacity < 0.999 else { return }

        // Match the old SwiftUI ease-out when a reading cools down or Reduce
        // Motion becomes active midway through its pulse.
        let settle = CABasicAnimation(keyPath: "opacity")
        settle.fromValue = fromOpacity
        settle.toValue = 1.0
        settle.duration = 0.2
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(settle, forKey: exitKey)
    }

    private static func setOpacity(_ opacity: Float, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }
}
