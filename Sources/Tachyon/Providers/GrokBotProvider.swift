import CommonCrypto
import Foundation

/// Grok Bot's separate usage pool via the desktop app's DashboardService.
///
/// Grok Bot stores its account token in `sand-secrets.json`, encrypted with
/// Electron Safe Storage. On macOS that means a password in the app-owned
/// Keychain item plus Chromium's `v10` envelope. Tachyon reads both sources
/// without modifying them, decrypts only in memory, and never refreshes tokens.
actor GrokBotProvider: UsageProvider {
    nonisolated let id = "grok-bot"
    nonisolated let displayName = "Grok Bot"
    nonisolated let shortName = "Grok"
    nonisolated let sourceLabel: String? = "Bot"
    nonisolated let glyph = ProviderGlyph.grokBot
    nonisolated let about: String? = "Grok Bot's separate provider-reported allowance."
    nonisolated let pollInterval: TimeInterval = 120

    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    private static let keychainService = "Grok Bot Safe Storage"
    private static let authGuidance = "Log in to Grok Bot"
    private static let secretsPath = Usage.homePath(
        "Library/Application Support/Grok Bot/sand-secrets.json"
    )
    private static let appPath = "/Applications/Grok Bot.app"
    private static let maxSecretsBytes = 2 * 1024 * 1024
    static let credentialCacheTTL: TimeInterval = 60

    struct Credential: Sendable, Equatable {
        let accessToken: String
        let accountScope: String
        let expiresAt: Date?

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }
    }

    struct Dependencies: Sendable {
        var isInstalled: @Sendable () -> Bool
        var readSecrets: @Sendable () -> Data?
        var readKeychain: @Sendable () async -> String?
        var fetchUsage: @Sendable (String) async throws -> Usage.HTTPResult
        var now: @Sendable () -> Date

        static let live = Dependencies(
            isInstalled: {
                Usage.fileExists(GrokBotProvider.appPath)
                    || Usage.fileExists(GrokBotProvider.secretsPath)
            },
            readSecrets: {
                Usage.boundedFile(
                    path: GrokBotProvider.secretsPath,
                    maximumBytes: GrokBotProvider.maxSecretsBytes
                )
            },
            readKeychain: {
                await Task.detached(priority: .utility) {
                    Usage.runCommand(
                        "/usr/bin/security",
                        ["find-generic-password", "-s", GrokBotProvider.keychainService, "-w"],
                        timeout: 8,
                        maximumOutputBytes: 4 * 1024
                    )
                }.value
            },
            fetchUsage: { token in
                try await Usage.post(
                    GrokBotProvider.usageURL,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json",
                        "Connect-Protocol-Version": "1",
                    ],
                    body: Data("{}".utf8)
                )
            },
            now: Date.init
        )
    }

    private struct AccountStore: Decodable {
        let active: String?
        let accounts: [String: [String: String]]
    }

    private struct CachedCredential: Sendable {
        let value: Credential
        let loadedAt: Date
    }

    private let dependencies: Dependencies
    private var cachedCredential: CachedCredential?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Presence and polling

    func detect() async -> ProviderPresence {
        guard dependencies.isInstalled() else { return .notInstalled }
        return await credential() == nil
            ? .notSignedIn(Self.authGuidance)
            : .ready
    }

    func snapshot() async -> ProviderState {
        guard let credential = await credential() else {
            return .authError(Self.authGuidance)
        }
        return await snapshot(using: credential)
    }

    func reading() async -> ProviderReading {
        guard let credential = await credential() else {
            return ProviderReading(
                state: .authError(Self.authGuidance),
                accountFingerprint: nil
            )
        }
        let state = await snapshot(using: credential)
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        return ProviderReading(
            state: state,
            accountFingerprint: state.isAuthError
                ? nil
                : Self.credentialFingerprint(credential)
        )
    }

    private func snapshot(using credential: Credential) async -> ProviderState {
        do {
            let result = try await dependencies.fetchUsage(credential.accessToken)
            guard !Task.isCancelled else { return .unavailable }
            if result.status == 401 {
                if cachedCredential?.value.accessToken == credential.accessToken {
                    cachedCredential = nil
                }
                return .authError(Self.authGuidance)
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("grok bot usage HTTP \(result.status)")
                return .unavailable
            }
            guard let snapshot = Self.decodeUsage(result.body, asOf: dependencies.now()) else {
                Log.provider.error("grok bot usage decode produced no usable window")
                return .unavailable
            }
            return .ok(snapshot)
        } catch {
            Log.provider.error("grok bot usage request failed")
            return .unavailable
        }
    }

    // MARK: - Credential chain

    private func credential() async -> Credential? {
        let now = dependencies.now()
        if let cachedCredential,
           Self.credentialCacheIsFresh(loadedAt: cachedCredential.loadedAt, now: now),
           !cachedCredential.value.isExpired(at: now) {
            return cachedCredential.value
        }
        cachedCredential = nil
        guard let data = dependencies.readSecrets(),
              let password = await dependencies.readKeychain(),
              let value = Self.loadCredential(secrets: data, password: password),
              !value.isExpired(at: dependencies.now()) else {
            return nil
        }
        cachedCredential = CachedCredential(value: value, loadedAt: dependencies.now())
        return value
    }

    static func credentialCacheIsFresh(loadedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(loadedAt)
        return age >= 0 && age < credentialCacheTTL
    }

    static func loadCredential(secrets data: Data, password: String) -> Credential? {
        let root = JSONValue.parse(data)
        guard let encodedAccounts = root["cursor-accounts"].string,
              let accountsData = encodedAccounts.data(using: .utf8),
              let store = try? JSONDecoder().decode(AccountStore.self, from: accountsData),
              let active = store.active,
              isOpaqueAccountScope(active),
              let encryptedToken = store.accounts[active]?["cursor-access-token"],
              let accessToken = decryptSafeStorage(encryptedToken, password: password),
              !accessToken.isEmpty else {
            return nil
        }
        return Credential(
            accessToken: accessToken,
            accountScope: active,
            expiresAt: Usage.jwtExpiry(accessToken)
        )
    }

    private static func isOpaqueAccountScope(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func decryptSafeStorage(_ encoded: String, password: String) -> String? {
        guard !password.isEmpty,
              let packed = Data(base64Encoded: encoded),
              packed.count > 3,
              Array(packed.prefix(3)) == Array("v10".utf8),
              let key = safeStorageKey(password: password) else {
            return nil
        }
        return decryptAES128CBC(Data(packed.dropFirst(3)), key: key)
    }

    private static func safeStorageKey(password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let status = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decryptAES128CBC(_ ciphertext: Data, key: Data) -> String? {
        guard !ciphertext.isEmpty else { return nil }
        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let plaintextCapacity = plaintext.count
        var plaintextCount = 0
        let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    initializationVector.withUnsafeBytes { vectorBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            vectorBytes.baseAddress,
                            cipherBytes.baseAddress,
                            ciphertext.count,
                            plaintextBytes.baseAddress,
                            plaintextCapacity,
                            &plaintextCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        plaintext.count = plaintextCount
        return String(data: plaintext, encoding: .utf8)
    }

    private static func credentialFingerprint(_ credential: Credential) -> String? {
        OpaqueAccountIdentity.fingerprint(
            namespace: "grok-bot-credential",
            components: [credential.accessToken, credential.accountScope]
        )
    }

    // MARK: - Decoding

    static func decodeUsage(_ data: Data, asOf: Date) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        guard let percent = root["usagePercent"].double,
              percent.isFinite,
              percent >= 0 else {
            return nil
        }

        let periodStart = root["currentPeriodStart"].isoDate
        let nextReset = root["nextResetTimestampUtc"].isoDate
        let trialExpiry = root["sandTrialExpiresAt"].isoDate
        let isLiveTrial = trialExpiry.map { $0 > asOf } ?? false
        let reset = isLiveTrial ? nil : nextReset
        let duration = isLiveTrial ? nil : periodDuration(start: periodStart, end: reset)
        let primary = UsageWindow(
            label: isLiveTrial ? "Trial" : "Weekly",
            percentUsed: percent,
            resetsAt: reset,
            windowSeconds: duration
        )

        return UsageSnapshot(
            primary: primary,
            windows: [primary],
            asOf: asOf,
            detail: statusDetail(
                trialExpiry: trialExpiry,
                planLabel: root["grokPlanLabel"].string,
                asOf: asOf
            )
        )
    }

    private static func statusDetail(
        trialExpiry: Date?,
        planLabel: String?,
        asOf: Date
    ) -> String? {
        if let trialExpiry {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
            let verb = trialExpiry > asOf ? "ends" : "ended"
            return "Trial \(verb) \(formatter.string(from: trialExpiry))"
        }
        return meaningfulPlanLabel(planLabel)
    }

    private static func meaningfulPlanLabel(_ value: String?) -> String? {
        guard let label = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              label.caseInsensitiveCompare("Grok Bot Plan") != .orderedSame else {
            return nil
        }
        return String(label.prefix(80))
    }

    private static func periodDuration(start: Date?, end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let duration = end.timeIntervalSince(start)
        return duration.isFinite && duration > 0 ? duration : nil
    }
}
