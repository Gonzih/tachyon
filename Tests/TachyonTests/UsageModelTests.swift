import XCTest
@testable import Tachyon

private actor ModelTestProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let shortName = "Test"
    nonisolated let sourceLabel: String?
    nonisolated let glyph = ProviderGlyph.claude
    nonisolated let pollInterval: TimeInterval
    nonisolated let acceptedPathSuffix: String?

    private var detectedPresence: ProviderPresence
    private var currentState: ProviderState
    private var fingerprint: String?
    private var detectCalls = 0
    private var snapshotCalls = 0

    init(
        id: String,
        sourceLabel: String? = nil,
        pollInterval: TimeInterval = 10,
        presence: ProviderPresence = .ready,
        state: ProviderState,
        fingerprint: String? = nil,
        acceptedPathSuffix: String? = nil
    ) {
        self.id = id
        self.displayName = "Test \(id)"
        self.sourceLabel = sourceLabel
        self.pollInterval = pollInterval
        self.detectedPresence = presence
        self.currentState = state
        self.fingerprint = fingerprint
        self.acceptedPathSuffix = acceptedPathSuffix
    }

    func detect() async -> ProviderPresence {
        detectCalls += 1
        return detectedPresence
    }

    func snapshot() async -> ProviderState {
        snapshotCalls += 1
        return currentState
    }

    func reading() async -> ProviderReading {
        snapshotCalls += 1
        return ProviderReading(state: currentState, accountFingerprint: fingerprint)
    }

    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool {
        guard let acceptedPathSuffix else { return true }
        return changedPaths.contains(where: { $0.hasSuffix(acceptedPathSuffix) })
    }

    func setState(_ state: ProviderState) { currentState = state }
    func setFingerprint(_ fingerprint: String?) { self.fingerprint = fingerprint }

    func callCounts() -> (detect: Int, snapshot: Int) {
        (detectCalls, snapshotCalls)
    }
}

/// A provider whose await points are controlled by the test. This makes
/// disable/stop races deterministic instead of timing-dependent.
private actor SuspendingModelTestProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let shortName = "Suspending Test"
    nonisolated let glyph = ProviderGlyph.claude
    nonisolated let pollInterval: TimeInterval = 300
    nonisolated let watchPaths: [String]

    private let suspendsDetect: Bool
    private let suspendsSnapshot: Bool
    private let suspendsFileChanged: Bool
    private var detectContinuation: CheckedContinuation<ProviderPresence, Never>?
    private var snapshotContinuation: CheckedContinuation<ProviderState, Never>?
    private var fileChangedContinuation: CheckedContinuation<Void, Never>?
    private var detectCalls = 0
    private var snapshotCalls = 0
    private var fingerprintCalls = 0
    private var fileChangedCalls = 0

    init(
        id: String,
        suspendsDetect: Bool = false,
        suspendsSnapshot: Bool = false,
        suspendsFileChanged: Bool = false,
        watchPaths: [String] = []
    ) {
        self.id = id
        self.displayName = "Test \(id)"
        self.suspendsDetect = suspendsDetect
        self.suspendsSnapshot = suspendsSnapshot
        self.suspendsFileChanged = suspendsFileChanged
        self.watchPaths = watchPaths
    }

    func detect() async -> ProviderPresence {
        detectCalls += 1
        guard suspendsDetect else { return .ready }
        return await withCheckedContinuation { detectContinuation = $0 }
    }

    func snapshot() async -> ProviderState {
        snapshotCalls += 1
        guard suspendsSnapshot else { return .unavailable }
        return await withCheckedContinuation { snapshotContinuation = $0 }
    }

    func accountFingerprint() async -> String? {
        fingerprintCalls += 1
        return "synthetic-fingerprint"
    }

    func reading() async -> ProviderReading {
        let state = await snapshot()
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        fingerprintCalls += 1
        return ProviderReading(
            state: state,
            accountFingerprint: "synthetic-fingerprint"
        )
    }

    func fileChanged(_ path: String) async {
        fileChangedCalls += 1
        guard suspendsFileChanged else { return }
        await withCheckedContinuation { fileChangedContinuation = $0 }
    }

    func releaseDetect(_ presence: ProviderPresence) {
        let continuation = detectContinuation
        detectContinuation = nil
        continuation?.resume(returning: presence)
    }

    func releaseSnapshot(_ state: ProviderState) {
        let continuation = snapshotContinuation
        snapshotContinuation = nil
        continuation?.resume(returning: state)
    }

    func releaseFileChanged() {
        let continuation = fileChangedContinuation
        fileChangedContinuation = nil
        continuation?.resume()
    }

    func callCounts() -> (detect: Int, snapshot: Int, fingerprint: Int, fileChanged: Int) {
        (detectCalls, snapshotCalls, fingerprintCalls, fileChangedCalls)
    }
}

@MainActor
private final class MutableTestClock {
    var value: Date

    init(_ value: Date) { self.value = value }
}

final class UsageModelTests: XCTestCase {
    @MainActor
    func testFirstSeenSourcesEnableOnlyWhenDetectionFindsUsableState() async {
        let ready = ModelTestProvider(
            id: "first-seen-ready",
            state: .ok(Self.snapshot(percent: 31, asOf: Date()))
        )
        let signedOut = ModelTestProvider(
            id: "first-seen-signed-out",
            presence: .notSignedIn("Synthetic guidance"),
            state: .unavailable
        )
        let missing = ModelTestProvider(
            id: "first-seen-missing",
            presence: .notInstalled,
            state: .unavailable
        )
        var persisted: [String: Bool] = [:]
        let model = UsageModel(
            providers: [ready, signedOut, missing],
            providerPreference: { _ in nil },
            persistProviderEnabled: { enabled, id in persisted[id] = enabled }
        )
        model.start()
        defer { model.stop() }

        let classified = await eventually {
            persisted.count == 3 && model.slot(id: ready.id)?.ringPercent == 31
        }
        XCTAssertTrue(classified)
        XCTAssertEqual(persisted, [
            ready.id: true,
            signedOut.id: false,
            missing.id: false,
        ])
        XCTAssertEqual(model.slots.map(\.enabled), [true, false, false])
        let signedOutCalls = await signedOut.callCounts()
        let missingCalls = await missing.callCounts()
        XCTAssertEqual(signedOutCalls.snapshot, 0)
        XCTAssertEqual(missingCalls.snapshot, 0)
    }

    @MainActor
    func testDisabledProviderDoesNoWorkUntilEnabled() async {
        let snapshot = Self.snapshot(percent: 20, asOf: Date())
        let provider = ModelTestProvider(id: "disabled-test", state: .ok(snapshot))
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in false },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        model.start() // Lifecycle is idempotent; no duplicate scheduler.
        defer { model.stop() }

        try? await Task.sleep(for: .milliseconds(80))
        let disabledCounts = await provider.callCounts()
        XCTAssertEqual(disabledCounts.detect, 0)
        XCTAssertEqual(disabledCounts.snapshot, 0)

        model.setEnabled(true, for: provider.id)
        let polledAfterEnable = await eventually {
            await provider.callCounts().snapshot == 1
        }
        XCTAssertTrue(polledAfterEnable)
        let enabledCounts = await provider.callCounts()
        XCTAssertEqual(enabledCounts.detect, 1)
        XCTAssertEqual(model.slots.first?.ringPercent, 20)
    }

    @MainActor
    func testReenableClearsOldPollWhileAccountRevalidates() async {
        let provider = ModelTestProvider(
            id: "reenable-clears-old-poll-test",
            state: .ok(Self.snapshot(percent: 20, asOf: Date())),
            fingerprint: "synthetic-account"
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let loaded = await eventually {
            model.slots.first?.lastPolled != nil
                && model.slots.first?.accountFingerprint == "synthetic-account"
        }
        XCTAssertTrue(loaded)

        model.setEnabled(false, for: provider.id)
        model.setEnabled(true, for: provider.id)

        // These mutations are synchronous on MainActor; the replacement poll
        // cannot run until this test yields again.
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertEqual(model.slots.first?.awaitingFirstSnapshot, true)
        XCTAssertNil(model.slots.first?.accountFingerprint)
        XCTAssertNil(model.slots.first?.lastPolled)
    }

    @MainActor
    func testDisablingDuringDetectionDiscardsLateResultAndFollowOnWork() async {
        let provider = SuspendingModelTestProvider(
            id: "disable-during-detect-test",
            suspendsDetect: true
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        var changeCount = 0
        model.onSlotsChanged = { changeCount += 1 }
        model.start()
        defer { model.stop() }

        let detectStarted = await eventually { await provider.callCounts().detect == 1 }
        XCTAssertTrue(detectStarted)
        model.setEnabled(false, for: provider.id)
        let changesAfterDisable = changeCount
        await provider.releaseDetect(.ready)
        try? await Task.sleep(for: .milliseconds(80))

        let calls = await provider.callCounts()
        XCTAssertEqual(calls.snapshot, 0)
        XCTAssertEqual(calls.fingerprint, 0)
        XCTAssertEqual(changeCount, changesAfterDisable)
        XCTAssertEqual(model.slots.first?.presence, .notInstalled)
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertEqual(model.slots.first?.enabled, false)
    }

    @MainActor
    func testRapidDisableReenableDiscardsPreSwitchDetection() async {
        let provider = SuspendingModelTestProvider(
            id: "reenable-during-detect-test",
            suspendsDetect: true
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        var changeCount = 0
        model.onSlotsChanged = { changeCount += 1 }
        model.start()
        defer { model.stop() }

        let firstDetectStarted = await eventually { await provider.callCounts().detect == 1 }
        XCTAssertTrue(firstDetectStarted)
        model.setEnabled(false, for: provider.id)
        model.setEnabled(true, for: provider.id)
        let changesAfterRetoggle = changeCount

        await provider.releaseDetect(.ready)
        let replacementDetectStarted = await eventually {
            await provider.callCounts().detect == 2
        }
        XCTAssertTrue(replacementDetectStarted)
        XCTAssertEqual(changeCount, changesAfterRetoggle)
        XCTAssertEqual(model.slots.first?.presence, .notInstalled)
        let callsBeforeReplacement = await provider.callCounts()
        XCTAssertEqual(callsBeforeReplacement.snapshot, 0)

        await provider.releaseDetect(.ready)
        let replacementCompleted = await eventually {
            await provider.callCounts().fingerprint == 1
        }
        XCTAssertTrue(replacementCompleted)
        XCTAssertEqual(model.slots.first?.presence, .ready)
    }

    @MainActor
    func testStoppingDuringSnapshotCannotApplyOrRecreateWatcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = SuspendingModelTestProvider(
            id: "stop-during-snapshot-test",
            suspendsSnapshot: true,
            watchPaths: [directory.path]
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        var changeCount = 0
        model.onSlotsChanged = { changeCount += 1 }
        model.start()

        let snapshotStarted = await eventually { await provider.callCounts().snapshot == 1 }
        XCTAssertTrue(snapshotStarted)
        XCTAssertEqual(model.activeWatcherCount(for: provider.id), 1)
        model.stop()
        let changesAfterStop = changeCount
        let callsAfterStop = await provider.callCounts()
        XCTAssertEqual(model.activeWatcherCount(for: provider.id), 0)

        let snapshot = Self.snapshot(percent: 42, asOf: Date())
        await provider.releaseSnapshot(.ok(snapshot))
        try? await Task.sleep(for: .milliseconds(80))

        let calls = await provider.callCounts()
        XCTAssertEqual(calls.fingerprint, callsAfterStop.fingerprint)
        XCTAssertEqual(calls.fileChanged, callsAfterStop.fileChanged)
        XCTAssertEqual(changeCount, changesAfterStop)
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertEqual(model.slots.first?.awaitingFirstSnapshot, true)
        XCTAssertNil(model.slots.first?.lastPolled)
        XCTAssertEqual(model.activeWatcherCount(for: provider.id), 0)
    }

    @MainActor
    func testStopClearsLiveReadingUntilRestartRevalidates() async {
        let provider = SuspendingModelTestProvider(
            id: "stop-restart-reading-test",
            suspendsSnapshot: true
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()

        let firstStarted = await eventually { await provider.callCounts().snapshot == 1 }
        XCTAssertTrue(firstStarted)
        await provider.releaseSnapshot(.ok(Self.snapshot(percent: 31, asOf: Date())))
        let firstLoaded = await eventually { model.slots.first?.ringPercent == 31 }
        XCTAssertTrue(firstLoaded)
        XCTAssertNotNil(model.slots.first?.accountFingerprint)

        model.stop()
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertTrue(model.slots.first?.awaitingFirstSnapshot == true)
        XCTAssertNil(model.slots.first?.accountFingerprint)
        XCTAssertNil(model.slots.first?.lastPolled)

        model.start()
        let secondStarted = await eventually { await provider.callCounts().snapshot == 2 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertNil(model.slots.first?.ringPercent)
        XCTAssertNil(model.slots.first?.accountFingerprint)

        await provider.releaseSnapshot(.ok(Self.snapshot(percent: 72, asOf: Date())))
        let secondLoaded = await eventually { model.slots.first?.ringPercent == 72 }
        XCTAssertTrue(secondLoaded)
        model.stop()
    }

    @MainActor
    func testWatcherBurstsCoalesceAndStoppedWorkDoesNotRetainModel() async {
        let provider = SuspendingModelTestProvider(
            id: "watch-coalesce-test",
            suspendsFileChanged: true
        )
        weak var weakModel: UsageModel?

        do {
            let model = UsageModel(
                providers: [provider],
                providerPreference: { _ in true },
                persistProviderEnabled: { _, _ in }
            )
            weakModel = model
            model.start()
            let initialPoll = await eventually { await provider.callCounts().snapshot == 1 }
            XCTAssertTrue(initialPoll)

            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            let firstInvalidation = await eventually {
                await provider.callCounts().fileChanged == 1
            }
            XCTAssertTrue(firstInvalidation)
            XCTAssertEqual(model.activeWatcherRefreshCount(for: provider.id), 1)

            // More identical writes while invalidation is suspended collapse
            // into one follow-up invalidation, followed by one poll signal.
            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            await provider.releaseFileChanged()
            let secondInvalidation = await eventually {
                await provider.callCounts().fileChanged == 2
            }
            XCTAssertTrue(secondInvalidation)
            await provider.releaseFileChanged()
            let refreshed = await eventually { await provider.callCounts().snapshot == 2 }
            XCTAssertTrue(refreshed)
            XCTAssertEqual(model.activeWatcherRefreshCount(for: provider.id), 0)

            // A suspended provider callback is canceled and detached from the
            // model lifecycle. Its eventual completion cannot trigger a poll.
            model.handleWatchChange(id: provider.id, changedPaths: ["/synthetic/Cookies"])
            let thirdInvalidation = await eventually {
                await provider.callCounts().fileChanged == 3
            }
            XCTAssertTrue(thirdInvalidation)
            model.stop()
            XCTAssertEqual(model.activeWatcherRefreshCount(for: provider.id), 0)
        }

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released)
        let snapshotsAtStop = await provider.callCounts().snapshot
        await provider.releaseFileChanged()
        try? await Task.sleep(for: .milliseconds(40))
        let snapshotsAfterRelease = await provider.callCounts().snapshot
        XCTAssertEqual(snapshotsAfterRelease, snapshotsAtStop)
    }

    @MainActor
    func testModelDeallocatesWhileProviderTaskIsSleeping() async {
        let provider = ModelTestProvider(
            id: "lifecycle-test",
            pollInterval: 300,
            state: .ok(Self.snapshot(percent: 10, asOf: Date()))
        )
        weak var weakModel: UsageModel?

        do {
            let model = UsageModel(
                providers: [provider],
                providerPreference: { _ in true },
                persistProviderEnabled: { _, _ in }
            )
            weakModel = model
            model.start()
            let firstPollFinished = await eventually {
                await provider.callCounts().snapshot == 1
            }
            XCTAssertTrue(firstPollFinished)
        }

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released)
    }

    @MainActor
    func testAuthFailureRetriesArePacedButManualRefreshStillWakes() async {
        let provider = ModelTestProvider(
            id: "auth-retry-test",
            pollInterval: 300,
            state: .authError("Synthetic sign-in guidance")
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let firstAttempt = await eventually {
            await provider.callCounts().snapshot == 1
        }
        XCTAssertTrue(firstAttempt)
        try? await Task.sleep(for: .milliseconds(80))
        let pacedCounts = await provider.callCounts()
        XCTAssertEqual(pacedCounts.snapshot, 1)

        model.refresh(id: provider.id)
        let explicitRetry = await eventually {
            await provider.callCounts().snapshot == 2
        }
        XCTAssertTrue(explicitRetry)
    }

    @MainActor
    func testWatcherBatchPassesAcceptedPathToCacheInvalidation() {
        let provider = ModelTestProvider(
            id: "path-filter-test",
            state: .unavailable,
            acceptedPathSuffix: "/Cookies"
        )
        let selected = UsageModel.refreshPath(
            for: provider,
            changedPaths: ["/synthetic/config.json", "/synthetic/Cookies"]
        )

        XCTAssertEqual(selected, "/synthetic/Cookies")
        XCTAssertNil(UsageModel.refreshPath(
            for: provider,
            changedPaths: ["/synthetic/config.json"]
        ))
    }

    @MainActor
    func testUnavailableReadingExpiresAfterBoundedGrace() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableTestClock(initialDate)
        let provider = ModelTestProvider(
            id: "stale-test",
            pollInterval: 10,
            state: .ok(Self.snapshot(percent: 42, asOf: initialDate))
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in },
            now: { clock.value }
        )
        model.start()
        defer { model.stop() }

        let loadedInitial = await eventually { model.slots.first?.ringPercent == 42 }
        XCTAssertTrue(loadedInitial)
        await provider.setState(.unavailable)
        model.refresh(id: provider.id)
        let becameStale = await eventually { model.slots.first?.state.isStale == true }
        XCTAssertTrue(becameStale)

        clock.value = initialDate.addingTimeInterval(31)
        model.refresh(id: provider.id)
        let expired = await eventually {
            guard let state = model.slots.first?.state else { return false }
            return state == .unavailable
        }
        XCTAssertTrue(expired)
    }

    @MainActor
    func testOldCurrentReadingCannotGainFreshGraceAfterDelayedFailure() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableTestClock(initialDate)
        let provider = ModelTestProvider(
            id: "delayed-stale-test",
            pollInterval: 10,
            state: .ok(Self.snapshot(percent: 42, asOf: initialDate))
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in },
            now: { clock.value }
        )
        model.start()
        defer { model.stop() }

        let loadedInitial = await eventually { model.slots.first?.ringPercent == 42 }
        XCTAssertTrue(loadedInitial)
        clock.value = initialDate.addingTimeInterval(31)
        await provider.setState(.unavailable)
        model.refresh(id: provider.id)

        let expired = await eventually {
            model.slots.first?.state == .unavailable
        }
        XCTAssertTrue(expired)
        XCTAssertNil(model.slots.first?.ringPercent)
    }

    @MainActor
    func testStaleDeadlineExpiresWithoutAnEarlyNetworkRetry() async {
        let provider = ModelTestProvider(
            id: "stale-deadline-test",
            pollInterval: 0.1,
            state: .ok(Self.snapshot(percent: 42, asOf: Date()))
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let loadedInitial = await eventually { model.slots.first?.ringPercent == 42 }
        XCTAssertTrue(loadedInitial)
        await provider.setState(.unavailable)
        model.refresh(id: provider.id)
        let becameStale = await eventually { model.slots.first?.state.isStale == true }
        XCTAssertTrue(becameStale)
        let callsAtStale = await provider.callCounts().snapshot

        let expired = await eventually(timeout: .seconds(1)) {
            model.slots.first?.state == .unavailable
        }
        XCTAssertTrue(expired)
        let callsAfterExpiry = await provider.callCounts().snapshot
        XCTAssertEqual(callsAfterExpiry, callsAtStale)
    }

    @MainActor
    func testVerifiedAccountSwitchNeverInheritsPreviousAccountsReading() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let provider = ModelTestProvider(
            id: "account-switch-test",
            state: .ok(Self.snapshot(percent: 42, asOf: initialDate)),
            fingerprint: "verified-account-a"
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let loadedInitial = await eventually { model.slots.first?.ringPercent == 42 }
        XCTAssertTrue(loadedInitial)

        await provider.setFingerprint("verified-account-b")
        await provider.setState(.unavailable)
        model.refresh(id: provider.id)

        let switched = await eventually {
            model.slots.first?.accountFingerprint == "verified-account-b"
        }
        XCTAssertTrue(switched)
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertNil(model.slots.first?.ringPercent)
    }

    @MainActor
    func testUnknownIdentityNeverInheritsPreviousVerifiedReading() async {
        let provider = ModelTestProvider(
            id: "unknown-identity-test",
            state: .ok(Self.snapshot(percent: 64, asOf: Date())),
            fingerprint: "verified-account"
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let loadedInitial = await eventually { model.slots.first?.ringPercent == 64 }
        XCTAssertTrue(loadedInitial)
        await provider.setFingerprint(nil)
        await provider.setState(.unavailable)
        model.refresh(id: provider.id)

        let identityCleared = await eventually {
            model.slots.first?.accountFingerprint == nil
                && model.slots.first?.awaitingFirstSnapshot == false
        }
        XCTAssertTrue(identityCleared)
        XCTAssertEqual(model.slots.first?.state, .unavailable)
        XCTAssertNil(model.slots.first?.ringPercent)
    }

    @MainActor
    func testProviderSuppliedStaleReadingCannotLiveForever() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableTestClock(initialDate)
        let snapshot = Self.snapshot(percent: 57, asOf: initialDate)
        let provider = ModelTestProvider(
            id: "source-stale-test",
            pollInterval: 10,
            state: .stale(snapshot, asOf: initialDate)
        )
        let model = UsageModel(
            providers: [provider],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in },
            now: { clock.value }
        )
        model.start()
        defer { model.stop() }

        let loadedFallback = await eventually { model.slots.first?.state.isStale == true }
        XCTAssertTrue(loadedFallback)
        clock.value = initialDate.addingTimeInterval(31)
        model.refresh(id: provider.id)
        let expired = await eventually { model.slots.first?.state == .unavailable }
        XCTAssertTrue(expired)

        model.refresh(id: provider.id)
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(
            model.slots.first?.state,
            .unavailable,
            "the same expired source record must not start a new grace window"
        )

        let newer = Self.snapshot(
            percent: 58,
            asOf: initialDate.addingTimeInterval(32)
        )
        await provider.setState(.stale(newer, asOf: newer.asOf))
        model.refresh(id: provider.id)
        let acceptedNewer = await eventually { model.slots.first?.ringPercent == 58 }
        XCTAssertTrue(acceptedNewer, "a genuinely newer fallback should re-arm the grace window")
    }

    @MainActor
    func testSourcesRemainSeparateEvenWhenFingerprintsMatch() {
        let older = Date(timeIntervalSince1970: 2_000_000_000)
        let code = Self.slot(
            id: "claude-code-test", source: "Code", fingerprint: "verified-same",
            state: .ok(Self.snapshot(percent: 20, asOf: older)))
        let desktop = Self.slot(
            id: "claude-desktop-test", source: "Desktop", fingerprint: "verified-same",
            state: .ok(Self.snapshot(percent: 65, asOf: older.addingTimeInterval(1))))

        XCTAssertEqual([code, desktop].count, 2)
        XCTAssertEqual(code.ringPercent, 20)
        XCTAssertEqual(desktop.ringPercent, 65)
        XCTAssertEqual(code.nameWithSource, "Synthetic Code")
        XCTAssertEqual(desktop.nameWithSource, "Synthetic Desktop")
    }

    @MainActor
    func testSignedOutDesktopCannotSuppressHealthyCode() async {
        let code = ModelTestProvider(
            id: "claude-code-test",
            sourceLabel: "Code",
            state: .ok(Self.snapshot(percent: 56, asOf: Date()))
        )
        let desktop = ModelTestProvider(
            id: "claude-desktop-test",
            sourceLabel: "Desktop",
            presence: .notSignedIn("Synthetic guidance"),
            state: .unavailable
        )
        let model = UsageModel(
            providers: [code, desktop],
            providerPreference: { _ in true },
            persistProviderEnabled: { _, _ in }
        )
        model.start()
        defer { model.stop() }

        let loaded = await eventually { model.slot(id: code.id)?.ringPercent == 56 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.visibleSlots.map(\.id), [code.id])
        XCTAssertEqual(model.slot(id: desktop.id)?.presence, .notSignedIn("Synthetic guidance"))
    }

    @MainActor
    func testStaleReadingCannotTriggerPaceUrgency() {
        let now = Date()
        let window = UsageWindow(
            label: "Session",
            percentUsed: 60,
            resetsAt: now.addingTimeInterval(1_800),
            windowSeconds: 3_600
        )
        let snapshot = UsageSnapshot(
            primary: window,
            windows: [window],
            asOf: now,
            detail: nil
        )
        let live = Self.slot(
            id: "live-pace-test",
            source: "Code",
            fingerprint: "verified-live",
            state: .ok(snapshot)
        )
        let stale = Self.slot(
            id: "stale-pace-test",
            source: "Desktop",
            fingerprint: "verified-stale",
            state: .stale(snapshot, asOf: snapshot.asOf),
            staleIndicatorDelay: 240
        )

        XCTAssertTrue(live.ringIsPaceHot)
        XCTAssertEqual(live.ringBandPercent, 70)
        XCTAssertFalse(stale.ringIsPaceHot)
        XCTAssertEqual(stale.ringBandPercent, 60)
        XCTAssertFalse(stale.displaysStale(at: now.addingTimeInterval(239)))
        XCTAssertTrue(stale.displaysStale(at: now.addingTimeInterval(240)))
    }

    @MainActor
    private func eventually(
        timeout: Duration = .seconds(2),
        _ predicate: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private static func snapshot(percent: Double, asOf: Date) -> UsageSnapshot {
        let window = UsageWindow(label: "Window", percentUsed: percent, resetsAt: nil)
        return UsageSnapshot(primary: window, windows: [window], asOf: asOf, detail: nil)
    }

    private static func slot(
        id: String,
        source: String,
        fingerprint: String?,
        state: ProviderState,
        staleIndicatorDelay: TimeInterval = 0
    ) -> ProviderSlot {
        ProviderSlot(
            id: id,
            displayName: "Synthetic",
            shortName: "Synthetic",
            glyph: .claude,
            isExperimental: false,
            providerSettings: [],
            about: nil,
            category: .subscription,
            sourceLabel: source,
            staleIndicatorDelay: staleIndicatorDelay,
            accountFingerprint: fingerprint,
            presence: .ready,
            state: state,
            enabled: true,
            lastPolled: state.snapshot?.asOf,
            awaitingFirstSnapshot: false
        )
    }
}
