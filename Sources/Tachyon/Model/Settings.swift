import AppKit
import Foundation

/// Thin, typed façade over `UserDefaults`. All persistence lives here.
enum Settings {
    private static var defaults: UserDefaults { .standard }

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
