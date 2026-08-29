import AppKit
import Foundation

/// Thin, typed façade over `UserDefaults`. All persistence lives here.
enum Settings {
    static var defaults: UserDefaults { .standard }

    private enum Key {
        static let providerEnabledPrefix = "provider.enabled."
        static let displayID = "display.id"
    }

    // MARK: Per-provider toggles

    static func providerEnabled(_ id: String) -> Bool {
        let key = Key.providerEnabledPrefix + id
        // Default on: zero-config means new providers light up without a visit to the menu.
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    /// Full key for a declared provider setting: "provider.<id>.<suffix>".
    /// (Never collides with "provider.enabled.<id>" — no provider is named
    /// "enabled".)
    private static func settingKey(_ suffix: String, provider id: String) -> String {
        "provider.\(id).\(suffix)"
    }

    /// Money: nil-safe — a missing key is nil, never 0. Clearing removes the
    /// key rather than writing 0 (0 would read as "budget of zero").
    static func moneySetting(_ suffix: String, provider id: String) -> Double? {
        guard let value = defaults.object(forKey: settingKey(suffix, provider: id)) as? Double,
              value > 0, value.isFinite else { return nil }
        return value
    }

    static func setMoneySetting(_ value: Double?, suffix: String, provider id: String) {
        let key = settingKey(suffix, provider: id)
        if let value, value > 0, value.isFinite {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func setProviderEnabled(_ enabled: Bool, for id: String) {
        defaults.set(enabled, forKey: Key.providerEnabledPrefix + id)
    }

    // MARK: Display selection

    /// `CGDirectDisplayID` of the preferred screen, if the user picked one.
    static var preferredDisplayID: CGDirectDisplayID? {
        get {
            guard defaults.object(forKey: Key.displayID) != nil else { return nil }
            let raw = defaults.integer(forKey: Key.displayID)
            return raw > 0 ? CGDirectDisplayID(raw) : nil
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Key.displayID)
            } else {
                defaults.removeObject(forKey: Key.displayID)
            }
        }
    }
}

extension NSScreen {
    /// The screen's `CGDirectDisplayID`, or nil if the device description lacks it.
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Resolves the user's preferred screen, falling back to main on disconnect.
    static func preferred() -> NSScreen? {
        if let wanted = Settings.preferredDisplayID,
           let match = NSScreen.screens.first(where: { $0.displayID == wanted }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
