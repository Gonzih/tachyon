import Foundation
import XCTest
@testable import Tachyon

@MainActor
final class ClaudeProviderTests: XCTestCase {
    private enum TestFailure: Error { case missingResponse }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func get() -> Value {
            lock.withLock { value }
        }

        func set(_ newValue: Value) {
            lock.withLock { value = newValue }
        }

        @discardableResult
        func update<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&value) }
        }
    }

    private actor ResponseRecorder {
        private var responses: [String: [Usage.HTTPResult]]
        private(set) var credentials: [String] = []

        init(_ responses: [String: [Usage.HTTPResult]]) {
            self.responses = responses
        }

        func fetch(_ credential: String) throws -> Usage.HTTPResult {
            credentials.append(credential)
            guard var queue = responses[credential], !queue.isEmpty else {
                throw TestFailure.missingResponse
            }
            let response = queue.removeFirst()
            responses[credential] = queue
            return response
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor SuspendedLoader<Value: Sendable> {
        private var loads: [CheckedContinuation<Value?, Never>?] = []
        private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func load() async -> Value? {
            await withCheckedContinuation { continuation in
                loads.append(continuation)
                let ready = countWaiters.filter { $0.count <= loads.count }
                countWaiters.removeAll { $0.count <= loads.count }
                ready.forEach { $0.continuation.resume() }
            }
        }

        func waitForLoadCount(_ count: Int) async {
            guard loads.count < count else { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((count, continuation))
            }
        }

        func resumeLoad(at index: Int, with value: Value?) {
            guard loads.indices.contains(index), let continuation = loads[index] else { return }
            loads[index] = nil
            continuation.resume(returning: value)
        }
    }

    private static let usageBody = Data(#"{"five_hour":{"utilization":25}}"#.utf8)

    private func credentialPayload(_ value: String, expiresAt: Date? = nil) -> String {
        let expiry = expiresAt.map {
            ",\"expiresAt\":\(Int64($0.timeIntervalSince1970 * 1_000))"
        } ?? ""
        return "{\"claudeAiOauth\":{\"accessToken\":\"\(value)\","
            + "\"subscriptionType\":\"max\"\(expiry)}}"
    }

    func testCredentialLocationsUseExactSecureStorageHash() {
        let overridden = ClaudeProvider.credentialLocations(
            claudeConfigDirectory: "/synthetic/config",
            secureStorageDirectory: "/synthetic/secure-store",
            homeDirectory: "/synthetic/home"
        )
        XCTAssertEqual(overridden.configDirectory, "/synthetic/config")
        XCTAssertEqual(overridden.filePath, "/synthetic/config/.credentials.json")
        XCTAssertEqual(overridden.keychainService, "Claude Code-credentials-26db743c")

        let inherited = ClaudeProvider.credentialLocations(
            claudeConfigDirectory: "/synthetic/config",
            secureStorageDirectory: nil,
            homeDirectory: "/synthetic/home"
        )
        XCTAssertEqual(inherited.keychainService, "Claude Code-credentials-050069d1")

        let explicitlyLegacy = ClaudeProvider.credentialLocations(
            claudeConfigDirectory: "/synthetic/config",
            secureStorageDirectory: "",
            homeDirectory: "/synthetic/home"
        )
        XCTAssertEqual(explicitlyLegacy.keychainService, "Claude Code-credentials")

        let composed = ClaudeProvider.credentialLocations(
            claudeConfigDirectory: nil,
            secureStorageDirectory: "/synthetic/Caf\u{00E9}",
            homeDirectory: "/synthetic/home"
        )
        let decomposed = ClaudeProvider.credentialLocations(
            claudeConfigDirectory: nil,
            secureStorageDirectory: "/synthetic/Cafe\u{0301}",
            homeDirectory: "/synthetic/home"
        )
        XCTAssertEqual(composed.keychainService, decomposed.keychainService)
    }

    func testUnauthorizedFileCredentialRetriesOnlyThatFile() async {
        let first = "synthetic-access-a"
        let second = "synthetic-access-b"
        let filePayloads = LockedBox([credentialPayload(first), credentialPayload(second)])
        let keychainReads = Counter()
        let recorder = ResponseRecorder([
            first: [.init(status: 401, body: Data())],
            second: [.init(status: 200, body: Self.usageBody)],
        ])

        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CONFIG_DIR" ? "/synthetic/config" : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in
                await keychainReads.increment()
                return nil
            },
            readFile: { _ in
                filePayloads.update { payloads in
                    guard payloads.count > 1 else { return payloads[0] }
                    return payloads.removeFirst()
                }
            },
            fetchUsage: { credential in try await recorder.fetch(credential) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let state = await provider.snapshot()
        guard case .ok(let snapshot) = state else {
            return XCTFail("a rotated credential from the same file should recover")
        }
        XCTAssertEqual(snapshot.primary.percentUsed, 25)
        let keychainReadCount = await keychainReads.value
        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(keychainReadCount, 1, "the retry must not walk the chain again")
        XCTAssertEqual(fetchedCredentials, [first, second])
    }

    func testUnauthorizedEnvironmentCredentialNeverFallsThrough() async {
        let credential = "synthetic-environment-access"
        let alternateKeychainReads = Counter()
        let alternateFileReads = LockedBox(0)
        let profileReads = Counter()
        let recorder = ResponseRecorder([
            credential: [.init(status: 403, body: Data())],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CODE_OAUTH_TOKEN" ? credential : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in
                await alternateKeychainReads.increment()
                return nil
            },
            readFile: { _ in
                alternateFileReads.update { $0 += 1 }
                return nil
            },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in
                await profileReads.increment()
                return .init(status: 200, body: Data())
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let state = await provider.snapshot()
        XCTAssertTrue(state.isAuthError)
        let fingerprint = await provider.accountFingerprint()
        let keychainReadCount = await alternateKeychainReads.value
        let profileReadCount = await profileReads.value
        XCTAssertNil(fingerprint)
        XCTAssertEqual(keychainReadCount, 0)
        XCTAssertEqual(alternateFileReads.get(), 0)
        XCTAssertEqual(profileReadCount, 0, "identity must not resend a rejected bearer")
    }

    func testUsageRequestPacingBlocksEarlyRefreshAndExtendsAfterThrottle() async {
        let credential = "synthetic-paced-access"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let sleeps = LockedBox<[TimeInterval]>([])
        let recorder = ResponseRecorder([
            credential: [
                .init(status: 200, body: Self.usageBody),
                .init(status: 429, body: Data()),
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CODE_OAUTH_TOKEN" ? credential : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in nil },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { clock.get() },
            sleep: { delay in
                sleeps.update { $0.append(delay) }
                clock.set(clock.get().addingTimeInterval(delay))
            }
        ))

        guard case .ok = await provider.snapshot() else { return XCTFail("expected baseline") }
        clock.set(clock.get().addingTimeInterval(55))
        guard case .stale = await provider.snapshot() else {
            return XCTFail("the paced request should reach the queued 429")
        }
        clock.set(clock.get().addingTimeInterval(60))
        guard case .ok = await provider.snapshot() else {
            return XCTFail("the post-throttle request should recover")
        }

        let recordedSleeps = sleeps.get()
        XCTAssertEqual(recordedSleeps.count, 2)
        XCTAssertEqual(recordedSleeps[0], 65, accuracy: 0.001)
        XCTAssertEqual(recordedSleeps[1], 240, accuracy: 0.001)
        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(fetchedCredentials, [credential, credential, credential])
    }

    func testCancelledPacingWaitDoesNotIssueAnotherRequest() async {
        let credential = "synthetic-cancelled-pace"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let recorder = ResponseRecorder([
            credential: [.init(status: 200, body: Self.usageBody)],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CODE_OAUTH_TOKEN" ? credential : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in nil },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { clock.get() },
            sleep: { _ in throw CancellationError() }
        ))

        guard case .ok = await provider.snapshot() else { return XCTFail("expected baseline") }
        clock.set(clock.get().addingTimeInterval(55))
        let cancelledState = await provider.snapshot()
        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(cancelledState, .unavailable)
        XCTAssertEqual(fetchedCredentials, [credential])
    }

    func testCredentialCacheExpiresAndDetectsSwitch() async {
        let first = "synthetic-cache-a"
        let second = "synthetic-cache-b"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let keychainPayload = LockedBox(credentialPayload(first))
        let recorder = ResponseRecorder([
            first: [
                .init(status: 200, body: Self.usageBody),
                .init(status: 200, body: Self.usageBody),
            ],
            second: [.init(status: 200, body: Self.usageBody)],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { _ in nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in keychainPayload.get() },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { clock.get() }
        ))

        _ = await provider.snapshot()
        keychainPayload.set(credentialPayload(second))
        clock.set(clock.get().addingTimeInterval(59))
        _ = await provider.snapshot()
        clock.set(clock.get().addingTimeInterval(2))
        _ = await provider.snapshot()

        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(fetchedCredentials, [first, first, second])
    }

    func testCredentialCacheRejectsBackwardClockJump() async {
        let first = "synthetic-clock-a"
        let second = "synthetic-clock-b"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let keychainPayload = LockedBox(credentialPayload(first))
        let recorder = ResponseRecorder([
            first: [.init(status: 200, body: Self.usageBody)],
            second: [.init(status: 200, body: Self.usageBody)],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { _ in nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in keychainPayload.get() },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { clock.get() }
        ))

        _ = await provider.snapshot()
        keychainPayload.set(credentialPayload(second))
        clock.set(clock.get().addingTimeInterval(-1))
        _ = await provider.snapshot()

        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(fetchedCredentials, [first, second])
    }

    func testExpiredKeychainCredentialFallsThroughToUsableFile() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = "synthetic-expired-keychain"
        let current = "synthetic-current-file"
        let expiredPayload = credentialPayload(expired, expiresAt: now.addingTimeInterval(-1))
        let currentPayload = credentialPayload(current, expiresAt: now.addingTimeInterval(3_600))
        let recorder = ResponseRecorder([
            current: [.init(status: 200, body: Self.usageBody)],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CONFIG_DIR" ? "/synthetic/config" : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in expiredPayload },
            readFile: { _ in currentPayload },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { now }
        ))

        let state = await provider.snapshot()
        guard case .ok = state else { return XCTFail("valid file credential should win") }
        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(fetchedCredentials, [current])
    }

    func testCancelledCredentialLoadCannotOverwriteNewerAccountCache() async {
        let first = "synthetic-cancelled-load-a"
        let second = "synthetic-current-load-b"
        let loader = SuspendedLoader<String>()
        let recorder = ResponseRecorder([
            second: [
                .init(status: 200, body: Self.usageBody),
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let firstPayload = credentialPayload(first)
        let secondPayload = credentialPayload(second)
        let provider = ClaudeProvider(dependencies: .init(
            environment: { _ in nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in await loader.load() },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let cancelled = Task { await provider.reading() }
        await loader.waitForLoadCount(1)
        cancelled.cancel()

        let current = Task { await provider.reading() }
        await loader.waitForLoadCount(2)
        await loader.resumeLoad(at: 1, with: secondPayload)
        guard case .ok = await current.value.state else {
            return XCTFail("new account should complete")
        }

        await loader.resumeLoad(at: 0, with: firstPayload)
        _ = await cancelled.value
        guard case .ok = await provider.snapshot() else {
            return XCTFail("new account should remain cached")
        }
        let fetchedCredentials = await recorder.credentials
        XCTAssertEqual(fetchedCredentials, [second, second])
    }

    func testReadingBindsIdentityToCredentialUsedBeforeCacheExpiry() async {
        let first = "synthetic-reading-a"
        let second = "synthetic-reading-b"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let environmentValue = LockedBox(first)
        let profiledCredentials = LockedBox<[String]>([])
        let usageBody = Self.usageBody
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in
                name == "CLAUDE_CODE_OAUTH_TOKEN" ? environmentValue.get() : nil
            },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in nil },
            readFile: { _ in nil },
            fetchUsage: { _ in
                // Model a slow request that crosses the credential TTL while
                // the harness switches accounts underneath Tachyon.
                environmentValue.set(second)
                clock.set(clock.get().addingTimeInterval(ClaudeProvider.credentialCacheTTL + 1))
                return .init(status: 200, body: usageBody)
            },
            fetchProfile: { credential in
                profiledCredentials.update { $0.append(credential) }
                let suffix = credential == first ? "a" : "b"
                return .init(status: 200, body: Data("""
                    {"account":{"uuid":"synthetic-account-\(suffix)"},
                     "organization":{"uuid":"synthetic-pool-\(suffix)"}}
                    """.utf8))
            },
            now: { clock.get() }
        ))

        let reading = await provider.reading()
        guard case .ok = reading.state else { return XCTFail("expected live usage") }
        XCTAssertEqual(profiledCredentials.get(), [first])
        XCTAssertEqual(
            reading.accountFingerprint,
            OpaqueAccountIdentity.fingerprint(
                namespace: "claude",
                components: ["synthetic-account-a", "synthetic-pool-a"]
            )
        )
    }

    func testLastGoodDoesNotCrossCredentialSwitch() async {
        let first = "synthetic-last-good-a"
        let second = "synthetic-last-good-b"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let keychainPayload = LockedBox(credentialPayload(first))
        let recorder = ResponseRecorder([
            first: [.init(status: 200, body: Self.usageBody)],
            second: [.init(status: 429, body: Data())],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { _ in nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in keychainPayload.get() },
            readFile: { _ in nil },
            fetchUsage: { value in try await recorder.fetch(value) },
            fetchProfile: { _ in .init(status: 500, body: Data()) },
            now: { clock.get() }
        ))

        guard case .ok = await provider.snapshot() else { return XCTFail("expected baseline") }
        keychainPayload.set(credentialPayload(second))
        clock.set(clock.get().addingTimeInterval(ClaudeProvider.credentialCacheTTL + 1))
        let switchedState = await provider.snapshot()
        XCTAssertEqual(switchedState, .unavailable)
    }

    func testProfileIdentityIsVerifiedCachedAndChangesWithCredential() async {
        let first = "synthetic-profile-a"
        let second = "synthetic-profile-b"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let environmentValue = LockedBox(first)
        let profileReads = Counter()
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CODE_OAUTH_TOKEN" ? environmentValue.get() : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in nil },
            readFile: { _ in nil },
            fetchUsage: { _ in .init(status: 500, body: Data()) },
            fetchProfile: { credential in
                await profileReads.increment()
                let suffix = credential == first ? "a" : "b"
                return .init(status: 200, body: Data("""
                    {"account":{"uuid":"synthetic-account-\(suffix)"},
                     "organization":{"uuid":"synthetic-pool-\(suffix)"}}
                    """.utf8))
            },
            now: { clock.get() }
        ))

        let firstFingerprint = await provider.accountFingerprint()
        let cachedFingerprint = await provider.accountFingerprint()
        let initialProfileReadCount = await profileReads.value
        XCTAssertEqual(firstFingerprint, cachedFingerprint)
        XCTAssertEqual(initialProfileReadCount, 1)

        environmentValue.set(second)
        clock.set(clock.get().addingTimeInterval(ClaudeProvider.credentialCacheTTL + 1))
        let secondFingerprint = await provider.accountFingerprint()
        let finalProfileReadCount = await profileReads.value
        XCTAssertNotNil(secondFingerprint)
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
        XCTAssertEqual(finalProfileReadCount, 2)
    }

    func testTransientProfileFailureRetriesAfterIdentityCacheTTL() async {
        let credential = "synthetic-profile-retry"
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let profiles = ResponseRecorder([
            credential: [
                .init(status: 500, body: Data()),
                .init(status: 200, body: Data("""
                    {"account":{"uuid":"synthetic-account-retry"},
                     "organization":{"uuid":"synthetic-pool-retry"}}
                    """.utf8)),
            ],
        ])
        let provider = ClaudeProvider(dependencies: .init(
            environment: { name in name == "CLAUDE_CODE_OAUTH_TOKEN" ? credential : nil },
            homeDirectory: { "/synthetic/home" },
            readKeychain: { _ in nil },
            readFile: { _ in nil },
            fetchUsage: { _ in .init(status: 500, body: Data()) },
            fetchProfile: { value in try await profiles.fetch(value) },
            now: { clock.get() }
        ))

        let initial = await provider.accountFingerprint()
        XCTAssertNil(initial)
        clock.set(clock.get().addingTimeInterval(59))
        let cachedFailure = await provider.accountFingerprint()
        XCTAssertNil(cachedFailure)
        clock.set(clock.get().addingTimeInterval(2))
        let recovered = await provider.accountFingerprint()
        XCTAssertNotNil(recovered)
        let fetches = await profiles.credentials
        XCTAssertEqual(fetches, [credential, credential])
    }
}
