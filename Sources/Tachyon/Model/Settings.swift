import AppKit
import Foundation
import Security

/// Thin, typed façade over `UserDefaults`. All persistence lives here.
enum Settings {
    static var defaults: UserDefaults { .standard }

    struct SecretSettingError: LocalizedError, Equatable {
        let status: OSStatus

        var errorDescription: String? {
            "Couldn\u{2019}t update the Keychain (error \(status))."
        }
    }

    private enum Key {
        static let providerEnabledPrefix = "provider.enabled."
        static let displayID = "display.id"
    }

    // MARK: Per-provider toggles

    /// Nil means this source has never been classified on this installation.
    /// UsageModel gives it one read-only detection pass, then persists the
    /// result so later launches preserve a stable source list.
    static func providerPreference(_ id: String) -> Bool? {
        let key = Key.providerEnabledPrefix + id
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    static func providerEnabled(_ id: String) -> Bool {
        // Unseen sources start enabled only long enough for first detection.
        providerPreference(id) ?? true
    }

    // MARK: Secrets (app-owned Keychain item, service "dev.gonzih.tachyon")

    static func secretSetting(_ suffix: String, provider id: String) -> String? {
        let account = settingKey(suffix, provider: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.gonzih.tachyon",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Updates an existing item in place, adding only when no item exists.
    /// Unlike delete-then-add, a failed write leaves the previous secret
    /// untouched. The result lets Settings surface a failure instead of
    /// pretending the new credential was saved.
    @discardableResult
    static func setSecretSetting(
        _ value: String?,
        suffix: String,
        provider id: String
    ) -> Result<Void, SecretSettingError> {
        let account = settingKey(suffix, provider: id)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.gonzih.tachyon",
            kSecAttrAccount as String: account,
        ]

        let result = applySecretMutation(
            value,
            currentValue: secretSetting(suffix, provider: id),
            update: { data in
                SecItemUpdate(
                    base as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            },
            add: { data in
                var item = base
                item[kSecValueData as String] = data
                return SecItemAdd(item as CFDictionary, nil)
            },
            delete: {
                SecItemDelete(base as CFDictionary)
            }
        )

        switch result {
        case .success(let changed):
            if changed { bumpSecretRevision(suffix, provider: id) }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Status-driven core kept separate so update/add/delete semantics can be
    /// tested without touching a developer's real Keychain.
    static func applySecretMutation(
        _ value: String?,
        currentValue: String? = nil,
        update: (Data) -> OSStatus,
        add: (Data) -> OSStatus,
        delete: () -> OSStatus
    ) -> Result<Bool, SecretSettingError> {
        guard let value, !value.isEmpty else {
            let status = delete()
            switch status {
            case errSecSuccess:
                return .success(true)
            case errSecItemNotFound:
                return .success(false)
            default:
                return .failure(SecretSettingError(status: status))
            }
        }

        if value == currentValue { return .success(false) }

        let data = Data(value.utf8)
        let updateStatus = update(data)
        switch updateStatus {
        case errSecSuccess:
            return .success(true)
        case errSecItemNotFound:
            let addStatus = add(data)
            guard addStatus == errSecSuccess else {
                return .failure(SecretSettingError(status: addStatus))
            }
            return .success(true)
        default:
            return .failure(SecretSettingError(status: updateStatus))
        }
    }

    /// Non-secret generation counter used to invalidate provider-local state
    /// when a credential changes. It reveals neither the credential nor an
    /// account identity.
    static func secretRevision(_ suffix: String, provider id: String) -> Int {
        max(0, defaults.integer(forKey: secretRevisionKey(suffix, provider: id)))
    }

    private static func bumpSecretRevision(_ suffix: String, provider id: String) {
        let key = secretRevisionKey(suffix, provider: id)
        let current = max(0, defaults.integer(forKey: key))
        defaults.set(current == Int.max ? 0 : current + 1, forKey: key)
    }

    private static func secretRevisionKey(_ suffix: String, provider id: String) -> String {
        "provider.secretRevision.\(id).\(suffix)"
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

    /// Resolves the user's preferred screen, falling back to the PRIMARY
    /// display. Never `.main`: main follows keyboard focus across monitors,
    /// and a drifting home screen splits the presence state machine from the
    /// pill's actual frame (pill docked on screen A while overlap and hot-zone
    /// tests run against screen B — shim vanishes, pill stays behind).
    static func preferred() -> NSScreen? {
        if let wanted = Settings.preferredDisplayID,
           let match = NSScreen.screens.first(where: { $0.displayID == wanted }) {
            return match
        }
        return NSScreen.screens.first
    }
}
