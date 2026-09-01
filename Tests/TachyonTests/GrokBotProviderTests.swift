import CommonCrypto
import Foundation
import XCTest
@testable import Tachyon

final class GrokBotProviderTests: XCTestCase {
    private let password = "test-only-\(UUID().uuidString)"
    private let token = "test-only.\(UUID().uuidString).not-a-jwt"
    private let accountScope = (UUID().uuidString + UUID().uuidString)
        .replacingOccurrences(of: "-", with: "")
        .lowercased()

    private var encryptedToken: String {
        Self.makeSyntheticSafeStorageEnvelope(token, password: password)
    }

    func testRegistryKeepsGrokBuildAndGrokBotSeparate() {
        let providers = ProviderRegistry.all
        let build = providers.first { $0.id == "grok" }
        let bot = providers.first { $0.id == "grok-bot" }

        XCTAssertEqual(build?.displayName, "Grok Build")
        XCTAssertEqual(build?.shortName, "Grok")
        XCTAssertEqual(build?.sourceLabel, "Build")
        XCTAssertEqual(bot?.displayName, "Grok Bot")
        XCTAssertEqual(bot?.shortName, "Grok")
        XCTAssertEqual(bot?.sourceLabel, "Bot")
        XCTAssertEqual(bot?.glyph, .grokBot)
    }

    func testDecryptsRuntimeGeneratedSyntheticSafeStorageEnvelope() {
        XCTAssertEqual(
            GrokBotProvider.decryptSafeStorage(encryptedToken, password: password),
            token
        )
        XCTAssertNil(GrokBotProvider.decryptSafeStorage(encryptedToken, password: UUID().uuidString))
        let invalidEnvelope = Data("not-an-electron-envelope".utf8).base64EncodedString()
        XCTAssertNil(GrokBotProvider.decryptSafeStorage(invalidEnvelope, password: password))
    }

    func testLoadsOnlyOpaqueActiveAccountCredential() throws {
        let credential = try XCTUnwrap(GrokBotProvider.loadCredential(
            secrets: secretsData(),
            password: password
        ))

        XCTAssertEqual(credential.accessToken, token)
        XCTAssertEqual(credential.accountScope, accountScope)
        XCTAssertNil(credential.expiresAt)
        XCTAssertNil(GrokBotProvider.loadCredential(
            secrets: secretsData(active: "not-an-opaque-account-scope"),
            password: password
        ))
    }

    func testDecodesWeeklyUsageAndProviderReset() throws {
        let asOf = try XCTUnwrap(DateParsing.iso8601("2026-09-01T17:00:00Z"))
        let data = Data(#"""
        {
          "usagePercent": 23.65,
          "currentPeriodStart": "2026-09-01T16:38:28.856Z",
          "nextResetTimestampUtc": "2026-09-08T16:38:28.856Z",
          "grokPlanLabel": "Grok Bot Plan"
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(GrokBotProvider.decodeUsage(data, asOf: asOf))
        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(snapshot.primary.percentUsed, 23.65)
        XCTAssertEqual(snapshot.primary.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(
            snapshot.primary.resetsAt,
            DateParsing.iso8601("2026-09-08T16:38:28.856Z")
        )
        XCTAssertNil(snapshot.detail)
    }

    func testTrialExpiryIsNotPresentedAsAReset() throws {
        let asOf = try XCTUnwrap(DateParsing.iso8601("2026-09-01T17:00:00Z"))
        let data = Data(#"""
        {
          "usagePercent": 19.85,
          "currentPeriodStart": "2026-09-01T16:38:28.856Z",
          "nextResetTimestampUtc": "2026-09-08T16:38:28.856Z",
          "sandTrialExpiresAt": "2026-09-08T16:38:28.856Z",
          "grokPlanLabel": "Grok Bot Plan"
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(GrokBotProvider.decodeUsage(data, asOf: asOf))
        XCTAssertEqual(snapshot.primary.label, "Trial")
        XCTAssertNil(snapshot.primary.resetsAt)
        XCTAssertNil(snapshot.primary.windowSeconds)
        XCTAssertEqual(snapshot.primary.percentUsed, 19.85)
        XCTAssertTrue(snapshot.detail?.hasPrefix("Trial ends ") == true)
        XCTAssertFalse(snapshot.detail?.contains("Grok Bot Plan") == true)
    }

    func testExpiredTrialRemainsVisibleWithoutBecomingAReset() throws {
        let asOf = try XCTUnwrap(DateParsing.iso8601("2026-09-09T17:00:00Z"))
        let data = Data(#"""
        {
          "usagePercent": 8,
          "currentPeriodStart": "2026-09-01T16:38:28.856Z",
          "nextResetTimestampUtc": "2026-09-15T16:38:28.856Z",
          "sandTrialExpiresAt": "2026-09-08T16:38:28.856Z",
          "grokPlanLabel": "Grok Bot Plan"
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(GrokBotProvider.decodeUsage(data, asOf: asOf))
        XCTAssertEqual(snapshot.primary.label, "Weekly")
        XCTAssertEqual(
            snapshot.primary.resetsAt,
            DateParsing.iso8601("2026-09-15T16:38:28.856Z")
        )
        XCTAssertTrue(snapshot.detail?.hasPrefix("Trial ended ") == true)
    }

    func testMissingUsagePercentFailsClosed() {
        let data = Data(#"{"nextResetTimestampUtc":"2026-09-08T16:38:28.856Z"}"#.utf8)
        XCTAssertNil(GrokBotProvider.decodeUsage(data, asOf: Date()))
    }

    func testProviderPipelineUsesInjectedReadOnlySources() async throws {
        let asOf = try XCTUnwrap(DateParsing.iso8601("2026-09-01T17:00:00Z"))
        let response = Data(#"""
        {
          "usagePercent": 25,
          "currentPeriodStart": "2026-09-01T16:38:28.856Z",
          "nextResetTimestampUtc": "2026-09-08T16:38:28.856Z",
          "grokPlanLabel": "Grok Bot Plan"
        }
        """#.utf8)
        let secrets = secretsData()
        let fixturePassword = password
        let provider = GrokBotProvider(dependencies: .init(
            isInstalled: { true },
            readSecrets: { secrets },
            readKeychain: { fixturePassword },
            fetchUsage: { _ in Usage.HTTPResult(status: 200, body: response) },
            now: { asOf }
        ))

        let presence = await provider.detect()
        XCTAssertEqual(presence, .ready)
        let state = await provider.snapshot()
        guard case .ok(let snapshot) = state else {
            return XCTFail("expected a current Grok Bot snapshot")
        }
        XCTAssertEqual(snapshot.primary.percentUsed, 25)
    }

    func testMissingKeychainAccessFailsAsAuthenticationError() async {
        let secrets = secretsData()
        let provider = GrokBotProvider(dependencies: .init(
            isInstalled: { true },
            readSecrets: { secrets },
            readKeychain: { nil },
            fetchUsage: { _ in XCTFail("usage request must not run"); throw FixtureError() },
            now: Date.init
        ))

        let presence = await provider.detect()
        XCTAssertEqual(presence, .notSignedIn("Log in to Grok Bot"))
        let state = await provider.snapshot()
        XCTAssertEqual(state, .authError("Log in to Grok Bot"))
    }

    func testNetworkAndUnauthorizedResponsesFailClosed() async {
        let secrets = secretsData()
        let fixturePassword = password
        let unavailableProvider = GrokBotProvider(dependencies: .init(
            isInstalled: { true },
            readSecrets: { secrets },
            readKeychain: { fixturePassword },
            fetchUsage: { _ in throw FixtureError() },
            now: Date.init
        ))
        let unauthorizedProvider = GrokBotProvider(dependencies: .init(
            isInstalled: { true },
            readSecrets: { secrets },
            readKeychain: { fixturePassword },
            fetchUsage: { _ in Usage.HTTPResult(status: 401, body: Data()) },
            now: Date.init
        ))

        let unavailable = await unavailableProvider.snapshot()
        XCTAssertEqual(unavailable, .unavailable)
        let unauthorized = await unauthorizedProvider.snapshot()
        XCTAssertEqual(unauthorized, .authError("Log in to Grok Bot"))
    }

    private func secretsData(active: String? = nil) -> Data {
        let selected = active ?? accountScope
        let accountRecord: [String: String] = ["cursor-access-token": encryptedToken]
        let accounts: [String: Any] = [
            "active": selected,
            "accounts": [selected: accountRecord],
        ]
        let encodedAccounts = try! JSONSerialization.data(withJSONObject: accounts)
        let accountsString = String(data: encodedAccounts, encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: [
            "cursor-accounts": accountsString,
        ])
    }

    private struct FixtureError: Error {}

    /// Builds a fresh fake Electron Safe Storage envelope for each test instance.
    /// No credential or encrypted credential fixture is stored in the repository.
    private static func makeSyntheticSafeStorageEnvelope(
        _ plaintext: String,
        password: String
    ) -> String {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let derivationStatus = password.withCString { passwordPointer in
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
        precondition(derivationStatus == kCCSuccess)

        let input = Data(plaintext.utf8)
        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var ciphertext = Data(count: input.count + kCCBlockSizeAES128)
        let ciphertextCapacity = ciphertext.count
        var ciphertextCount = 0
        let encryptionStatus = ciphertext.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    initializationVector.withUnsafeBytes { vectorBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            vectorBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            ciphertextCapacity,
                            &ciphertextCount
                        )
                    }
                }
            }
        }
        precondition(encryptionStatus == kCCSuccess)
        ciphertext.count = ciphertextCount
        return (Data("v10".utf8) + ciphertext).base64EncodedString()
    }
}
