import SwiftUI

// MARK: - Geometry constants

/// Single source of truth for pill layout. `PillPanel` sizes itself from these,
/// and `ShimPanel` matches the total height so the two line up exactly.
enum PillMetrics {
    static let width: CGFloat = 64
    static let cornerRadius: CGFloat = 24
    static let ringDiameter: CGFloat = 36
    static let ringStroke: CGFloat = 3.5
    static let glyphSize: CGFloat = 16
    static let labelHeight: CGFloat = 16
    static let ringLabelGap: CGFloat = 4
    static let moduleHeight: CGFloat = ringDiameter + ringLabelGap + labelHeight  // 56
    static let moduleSpacing: CGFloat = 18
    static let verticalPadding: CGFloat = 16

    /// Body height: 1 → 88, 2 → 162, 3 → 236.
    static func height(moduleCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return verticalPadding * 2
            + CGFloat(count) * moduleHeight
            + CGFloat(count - 1) * moduleSpacing
    }

    /// The concave tapers sweep one radius above and below the body, so the
    /// hosting panel must be that much taller or they get clipped away.
    static func panelHeight(moduleCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return height(moduleCount: count) + cornerRadius * 2
    }

    /// Distance from the top of the *panel* to the top of module `index`.
    private static func moduleTop(index: Int) -> CGFloat {
        cornerRadius + verticalPadding + CGFloat(index) * (moduleHeight + moduleSpacing)
    }

    /// Center y of module `index`'s *ring*, measured from the panel top. The
    /// popover tail points here, not at the module's midpoint.
    static func ringCenterY(index: Int) -> CGFloat {
        moduleTop(index: index) + ringDiameter / 2
    }

    /// Maps a y in panel coordinates (top-left origin) to the module under it.
    /// The gap between modules is split between its neighbours so there is no
    /// dead band where a hover does nothing.
    static func moduleIndex(atY y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        for index in 0..<count {
            let top = moduleTop(index: index)
            if y >= top - moduleSpacing / 2, y <= top + moduleHeight + moduleSpacing / 2 {
                return index
            }
        }
        return nil
    }
}

// MARK: - Pill silhouette

/// The Figma silhouette: flat right side flush to the screen edge, 24pt convex
/// corners on the left, and 24pt **concave** quarter-arcs sweeping the top and
/// bottom edges back into the screen edge.
///
/// `rect` is the pill body. The concave arcs are drawn in the `cornerRadius`
/// margin above and below it, so the hosting panel must be that much taller.
struct PillShape: Shape {
    var radius: CGFloat = PillMetrics.cornerRadius

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width)
        // The body is inset vertically so the tapers have room inside `rect`.
        let body = rect.insetBy(dx: 0, dy: r)
        guard body.height > 0 else { return Path(rect) }

        var path = Path()
        // Start on the screen edge, at the top of the taper.
        path.move(to: CGPoint(x: body.maxX, y: rect.minY))
        // Top concave taper: centered on the edge above the body, sweeping in.
        path.addArc(
            center: CGPoint(x: body.maxX - r, y: rect.minY),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
        // Top-left convex corner.
        path.addArc(
            center: CGPoint(x: body.minX + r, y: body.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
        // Bottom-left convex corner.
        path.addArc(
            center: CGPoint(x: body.minX + r, y: body.maxY - r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
        // Bottom concave taper: mirror of the top.
        path.addArc(
            center: CGPoint(x: body.maxX - r, y: rect.maxY),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Ring module

/// One provider's ring: track, usage arc, glyph, percent label.
struct RingModule: View {
    let slot: ProviderSlot
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme(colorScheme) }

    private var percent: Double? { slot.ringPercent }

    /// Stale readings keep their real colors at reduced opacity; unavailable and
    /// pre-first-snapshot states go to a bare track.
    private var contentOpacity: Double {
        if slot.state.isAuthError { return 0.5 }
        if percent == nil && slot.ringSpend == nil { return 0.5 }
        // A reading one poll old is effectively fresh — dimming it just makes
        // the ring look sick every time the endpoint throttles once. Only dim
        // when the data is meaningfully old.
        if let since = slot.state.staleSince,
           Date().timeIntervalSince(since) > 10 * 60 { return 0.7 }
        return 1.0
    }

    private var arcColor: Color {
        guard let percent else { return .clear }
        return UsageColor.band(percent, theme: theme)
    }

    /// Percent wins when both exist (a budgeted spend window) — same
    /// precedence as every other surface.
    private var labelText: String {
        if let percent { return "\(Int(percent.rounded()))%" }
        if let spend = slot.ringSpend { return UsageWindow.formatSpend(spend) }
        return "–"
    }

    var body: some View {
        VStack(spacing: PillMetrics.ringLabelGap) {
            ZStack {
                Circle()
                    .stroke(theme.track(0.2), lineWidth: PillMetrics.ringStroke)

                if let percent {
                    Circle()
                        .trim(from: 0, to: max(0.0001, percent / 100))
                        .stroke(
                            arcColor,
                            style: StrokeStyle(lineWidth: PillMetrics.ringStroke, lineCap: .round)
                        )
                        // Arc starts at 12 o'clock and sweeps clockwise.
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: percent)
                }

                GlyphView(glyph: slot.glyph, size: PillMetrics.glyphSize, color: theme.fg)

                if slot.state.isAuthError {
                    // "!" badge sits at the ring's lower-right, outside the glyph.
                    Text("!")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(UsageColor.orange))
                        .offset(x: PillMetrics.ringDiameter / 2 - 3, y: PillMetrics.ringDiameter / 2 - 3)
                }
            }
            .frame(width: PillMetrics.ringDiameter, height: PillMetrics.ringDiameter)

            Text(labelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.fg)
                .monospacedDigit()
                .frame(height: PillMetrics.labelHeight)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: labelText)
        }
        .frame(width: PillMetrics.width, height: PillMetrics.moduleHeight)
        .opacity(contentOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slot.displayName) \(labelText) used")
    }
}

// MARK: - Pill

/// The pill's whole content: silhouette plus one ring per visible provider.
struct PillView: View {
    let slots: [ProviderSlot]
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme(colorScheme) }

    var body: some View {
        ZStack(alignment: .top) {
            PillShape()
                .fill(theme.surface)
            PillShape()
                .stroke(theme.border, lineWidth: 1)

            VStack(spacing: PillMetrics.moduleSpacing) {
                ForEach(slots) { slot in
                    RingModule(slot: slot)
                }
            }
            // Taper margin first, then the body's own padding.
            .padding(.top, PillMetrics.cornerRadius + PillMetrics.verticalPadding)
        }
        .frame(
            width: PillMetrics.width,
            height: PillMetrics.panelHeight(moduleCount: slots.count)
        )
    }
}
