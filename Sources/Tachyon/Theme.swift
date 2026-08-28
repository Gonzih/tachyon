import SwiftUI

/// Semantic colors for both appearances. Dark is the original design; light is
/// its mirror — a warm off-white surface, near-black content, and slightly
/// deepened band colors so they hold contrast on white.
struct Theme {
    let isDark: Bool

    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    /// Pill and popover surface.
    var surface: Color { isDark ? .black : Color(white: 0.98) }

    /// Primary content (glyphs, headline text).
    var fg: Color { isDark ? .white : Color(white: 0.13) }

    /// Content at reduced emphasis. Light mode runs slightly stronger than a
    /// naive alpha copy because dark-on-light needs more ink to read.
    func fg(_ alpha: Double) -> Color {
        isDark ? .white.opacity(alpha) : Color(white: 0.13).opacity(min(1, alpha * 1.1))
    }

    /// Neutral fills: ring tracks, bar tracks, badges.
    func track(_ alpha: Double) -> Color {
        isDark ? .white.opacity(alpha) : .black.opacity(alpha * 0.65)
    }

    /// Hairline that gives light surfaces definition against a light desktop.
    var border: Color { isDark ? .clear : .black.opacity(0.10) }
}

extension UsageColor {
    /// Scheme-aware bands: dark keeps the original vivid set; light deepens
    /// each hue so it carries on a white surface (yellow especially).
    static func band(_ percent: Double, theme: Theme) -> Color {
        guard !theme.isDark else { return band(percent) }
        switch percent {
        case ..<50: return Color(red: 0x24 / 255, green: 0xA1 / 255, blue: 0x48 / 255)
        case ..<70: return Color(red: 0xDF / 255, green: 0xA4 / 255, blue: 0x00 / 255)
        case ..<90: return Color(red: 0xE8 / 255, green: 0x86 / 255, blue: 0x00 / 255)
        default: return Color(red: 0xE5 / 255, green: 0x34 / 255, blue: 0x2B / 255)
        }
    }

    static func nsBand(_ percent: Double, darkAppearance: Bool) -> NSColor {
        guard !darkAppearance else { return nsBand(percent) }
        switch percent {
        case ..<50: return NSColor(red: 0x24 / 255, green: 0xA1 / 255, blue: 0x48 / 255, alpha: 1)
        case ..<70: return NSColor(red: 0xDF / 255, green: 0xA4 / 255, blue: 0x00 / 255, alpha: 1)
        case ..<90: return NSColor(red: 0xE8 / 255, green: 0x86 / 255, blue: 0x00 / 255, alpha: 1)
        default: return NSColor(red: 0xE5 / 255, green: 0x34 / 255, blue: 0x2B / 255, alpha: 1)
        }
    }
}

extension NSAppearance {
    var isDarkTheme: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
