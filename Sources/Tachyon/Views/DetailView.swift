import SwiftUI

/// Reset/freshness formatting. Deliberately outside `DetailView` (which is
/// `View`, hence main-actor bound) so the headless diagnostic can call it too.
enum ResetFormat {
    /// nil → omitted · past → "resetting…" · <90min → "Resets in N min" ·
    /// same day → "Resets at h:mm a" · else → "Resets Thu 12:00 AM".
    static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "resetting…" }
        if delta < 90 * 60 {
            let minutes = max(1, Int((delta / 60).rounded()))
            return "Resets in \(minutes) min"
        }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "Resets at \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: date))"
    }

    /// "just now" / "2m ago" / "3h ago" / "2d ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}

/// Popover body: header, one bar per `UsageWindow`, freshness + plan footer.
struct DetailView: View {
    let slot: ProviderSlot
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme(colorScheme) }

    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 14

    private var rows: [UsageWindow] {
        slot.snapshot?.windows ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let guidance = slot.state.authGuidance {
                Text(guidance)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else if rows.isEmpty {
                Text("No usage data available")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg(0.5))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, window in
                        WindowRow(window: window)
                    }
                }
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.fg(0.4))
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            GlyphView(glyph: slot.glyph, size: 14, color: theme.fg)
            Text(slot.shortName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.fg)
            if slot.isExperimental {
                Text("EXPERIMENTAL")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.fg(0.55))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.track(0.12))
                    )
            }
        }
    }

    private var footer: String? {
        var parts: [String] = []
        if slot.state.isStale, let asOf = slot.snapshot?.asOf {
            parts.append("as of \(ResetFormat.relative(asOf))")
        }
        if let detail = slot.snapshot?.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Label + reset time, a 4pt bar, and the percent caption.
private struct WindowRow: View {
    let window: UsageWindow

    private var caption: String {
        if let spend = window.spendUSD, let budget = window.budgetUSD {
            return "\(Self.money(spend)) of \(Self.money(budget))"
        }
        if let percent = window.percentUsed { return "\(Int(percent.rounded()))% Used" }
        if let spend = window.spendUSD { return "\(UsageWindow.formatSpend(spend)) spent" }
        if let count = window.count { return "\(count) \(window.countUnit ?? "")" }
        return ""
    }

    /// "$34.20", "$50" — cents when fractional, clean integers otherwise.
    private static func money(_ usd: Double) -> String {
        usd.truncatingRemainder(dividingBy: 1) == 0
            ? "$\(Int(usd))"
            : String(format: "$%.2f", usd)
    }
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let reset = ResetFormat.resetText(window.resetsAt) {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fg(0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track(0.15))
                    if let percent = window.percentUsed {
                        Capsule()
                            .fill(UsageColor.band(window.bandPercent ?? percent, theme: theme))
                            .frame(width: geometry.size.width * percent / 100)
                    }
                }
            }
            .frame(height: 4)

            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(theme.fg(0.7))
        }
    }
}
