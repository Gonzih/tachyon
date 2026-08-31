import Foundation
import Security
import XCTest
@testable import Tachyon

final class SettingsWindowStateTests: XCTestCase {
    func testLaunchAtLoginSynchronizationDoesNotBecomeAUserRequest() {
        var state = LaunchAtLoginControlState()
        XCTAssertEqual(state.request(for: true), .register)

        state.synchronize(isEnabled: true, requiresApproval: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.requiresApproval)
        XCTAssertNil(state.request(for: true))
        XCTAssertEqual(state.request(for: false), .unregister)

        state.synchronize(isEnabled: false, requiresApproval: true)
        XCTAssertFalse(state.isEnabled)
        XCTAssertTrue(state.requiresApproval)
        XCTAssertNil(state.request(for: false))
    }

    func testExistingSecretUsesEmptyInputAndRequiresExplicitClear() {
        var state = SecretFieldState()
        state.input = "unsaved"
        state.synchronize(hasExistingSecret: true)

        XCTAssertTrue(state.hasExistingSecret)
        XCTAssertEqual(state.input, "")
        XCTAssertEqual(state.replacementButtonTitle, "Replace")
        XCTAssertFalse(state.canSubmitReplacement)
        XCTAssertEqual(state.submission(), .noChange)
        XCTAssertEqual(state.clearAction, .clear)

        state.input = SecretFieldState.existingSecretMask
        XCTAssertTrue(state.canSubmitReplacement)
        XCTAssertEqual(state.submission(), .invalidPresentationMask)
        state.input = "prefix\(SecretFieldState.existingSecretMask)suffix"
        XCTAssertEqual(state.submission(), .invalidPresentationMask)
    }

    func testSecretReplacementAndClearTransitionsNeverUsePresentationMask() {
        var state = SecretFieldState()
        state.input = "  synthetic-new-secret\n"
        let replacement = SecretFieldState.Action.replace("synthetic-new-secret")
        XCTAssertEqual(state.submission(), .action(replacement))

        state.didPersist(replacement)
        XCTAssertTrue(state.hasExistingSecret)
        XCTAssertEqual(state.input, "")

        state.didPersist(.clear)
        XCTAssertFalse(state.hasExistingSecret)
        XCTAssertEqual(state.input, "")
        XCTAssertEqual(state.replacementButtonTitle, "Save")
        XCTAssertNil(state.clearAction)
    }

    func testSecretDiscardClearsPlaintextWithoutForgettingSavedState() {
        var state = SecretFieldState()
        state.synchronize(hasExistingSecret: true)
        state.input = "synthetic-unsaved-plaintext"

        state.discardInput()

        XCTAssertEqual(state.input, "")
        XCTAssertTrue(state.hasExistingSecret)
        XCTAssertEqual(state.replacementButtonTitle, "Replace")
        XCTAssertEqual(state.submission(), .noChange)
    }

    func testMoneySaveStateWritesOnlyAfterAnEditAndResetsAfterCommit() {
        var state = MoneyFieldState()
        state.synchronize(value: 12)
        XCTAssertEqual(state.input, "$12")
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.submission(), .noChange)

        state.updateInput(" $15.50 ")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.submission(), .save(15.5))

        // A successful commit re-synchronizes the field. A subsequent Return
        // or button click is a no-op instead of a duplicate persistence call.
        state.synchronize(value: 15.5)
        XCTAssertEqual(state.input, "$15.50")
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.submission(), .noChange)
    }

    func testMoneySaveStateKeepsExplicitClearSemantics() {
        var state = MoneyFieldState()
        state.synchronize(value: 20)
        state.updateInput("junk")
        XCTAssertEqual(state.submission(), .save(nil))
    }

    func testProviderSettingsStatusPrioritizesDisabledThenChecking() {
        XCTAssertEqual(ProviderSettingsStatusLine.text(
            enabled: false,
            awaitingFirstSnapshot: true,
            presence: .ready,
            state: .unavailable,
            lastPolled: nil
        ), "Disabled")
        XCTAssertEqual(ProviderSettingsStatusLine.text(
            enabled: true,
            awaitingFirstSnapshot: true,
            presence: .ready,
            state: .unavailable,
            lastPolled: nil
        ), "Checking…")
    }

    func testProviderSettingsStatusPreservesReadyAndStaleDetail() {
        let plainWindow = UsageWindow(label: "Synthetic", percentUsed: 20, resetsAt: nil)
        let plain = UsageSnapshot(
            primary: plainWindow,
            windows: [plainWindow],
            asOf: Date(),
            detail: nil
        )
        XCTAssertEqual(ProviderSettingsStatusLine.text(
            enabled: true,
            awaitingFirstSnapshot: false,
            presence: .ready,
            state: .ok(plain),
            lastPolled: nil
        ), "Ready")

        let detailed = UsageSnapshot(
            primary: plainWindow,
            windows: [plainWindow],
            asOf: plain.asOf,
            detail: "Synthetic plan"
        )
        XCTAssertEqual(ProviderSettingsStatusLine.text(
            enabled: true,
            awaitingFirstSnapshot: false,
            presence: .ready,
            state: .stale(detailed, asOf: detailed.asOf),
            lastPolled: nil
        ), "stale · Synthetic plan")
        XCTAssertEqual(ProviderSettingsStatusLine.text(
            enabled: true,
            awaitingFirstSnapshot: false,
            presence: .ready,
            state: .stale(detailed, asOf: detailed.asOf),
            lastPolled: nil,
            displaysStale: false
        ), "Synthetic plan")
    }
}

final class SettingsSecretMutationTests: XCTestCase {
    func testUnchangedSecretDoesNotWriteOrAdvanceCredentialGeneration() {
        let result = Settings.applySecretMutation(
            "synthetic-same-value",
            currentValue: "synthetic-same-value",
            update: { _ in XCTFail("same value must not update"); return errSecSuccess },
            add: { _ in XCTFail("same value must not add"); return errSecSuccess },
            delete: { XCTFail("same value must not delete"); return errSecSuccess }
        )

        guard case .success(let changed) = result else {
            return XCTFail("same-value save should succeed as a no-op")
        }
        XCTAssertFalse(changed)
    }

    func testFailedUpdatePreservesExistingItem() {
        var addCalls = 0
        var deleteCalls = 0

        let result = Settings.applySecretMutation(
            "synthetic-new-value",
            update: { _ in errSecAuthFailed },
            add: { _ in
                addCalls += 1
                return errSecSuccess
            },
            delete: {
                deleteCalls += 1
                return errSecSuccess
            }
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected the failed update to be reported")
        }
        XCTAssertEqual(error.status, errSecAuthFailed)
        XCTAssertEqual(addCalls, 0)
        XCTAssertEqual(deleteCalls, 0, "replacement must never delete the old item")
    }

    func testMissingItemFallsBackToAddWithoutDelete() {
        var addedValue: String?
        var deleteCalls = 0

        let result = Settings.applySecretMutation(
            "synthetic-new-value",
            update: { _ in errSecItemNotFound },
            add: { data in
                addedValue = String(data: data, encoding: .utf8)
                return errSecSuccess
            },
            delete: {
                deleteCalls += 1
                return errSecSuccess
            }
        )

        guard case .success(let changed) = result else {
            return XCTFail("expected add to succeed")
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(addedValue, "synthetic-new-value")
        XCTAssertEqual(deleteCalls, 0)
    }

    func testDeletingMissingItemIsSuccessfulNoOp() {
        let result = Settings.applySecretMutation(
            nil,
            update: { _ in XCTFail("delete must not update"); return errSecSuccess },
            add: { _ in XCTFail("delete must not add"); return errSecSuccess },
            delete: { errSecItemNotFound }
        )

        guard case .success(let changed) = result else {
            return XCTFail("a missing item is already deleted")
        }
        XCTAssertFalse(changed)
    }
}

final class ProviderAncillaryHardeningTests: XCTestCase {
    func testGrokLogFreshnessRejectsOldAndMateriallyFutureRecords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(GrokProvider.logTimestampIsFresh(
            now.addingTimeInterval(-300),
            now: now
        ))
        XCTAssertFalse(GrokProvider.logTimestampIsFresh(
            now.addingTimeInterval(-301),
            now: now
        ))
        XCTAssertTrue(GrokProvider.logTimestampIsFresh(
            now.addingTimeInterval(60),
            now: now
        ))
        XCTAssertFalse(GrokProvider.logTimestampIsFresh(
            now.addingTimeInterval(61),
            now: now
        ))
        XCTAssertNotEqual(
            GrokProvider.credentialFingerprint(
                key: "synthetic-grok-a",
                userID: "synthetic-user-a"
            ),
            GrokProvider.credentialFingerprint(
                key: "synthetic-grok-b",
                userID: "synthetic-user-b"
            )
        )
        XCTAssertNotNil(GrokProvider.credentialFingerprint(
            key: "synthetic-grok-without-user-id",
            userID: nil
        ))
    }

    func testCursorCredentialCacheHasStrictTTL() {
        let loadedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(CursorProvider.credentialCacheIsFresh(
            loadedAt: loadedAt,
            now: loadedAt.addingTimeInterval(CursorProvider.credentialCacheTTL - 0.001)
        ))
        XCTAssertFalse(CursorProvider.credentialCacheIsFresh(
            loadedAt: loadedAt,
            now: loadedAt.addingTimeInterval(CursorProvider.credentialCacheTTL)
        ))
        XCTAssertFalse(CursorProvider.credentialCacheIsFresh(
            loadedAt: loadedAt,
            now: loadedAt.addingTimeInterval(-1)
        ))
        XCTAssertNotEqual(
            CursorProvider.credentialFingerprint(
                accessToken: "synthetic-cursor-a",
                membership: "pro"
            ),
            CursorProvider.credentialFingerprint(
                accessToken: "synthetic-cursor-b",
                membership: "pro"
            )
        )
        XCTAssertNotNil(CursorProvider.credentialFingerprint(
            accessToken: "synthetic-cursor-without-membership",
            membership: nil
        ))
    }

    func testOpenRouterBaselineIsIsolatedBySecretRevision() throws {
        let suiteName = "dev.gonzih.tachyon.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let components = Calendar.current.dateComponents([.year, .month], from: now)

        // Preserve a legacy baseline for the original revision.
        defaults.set("\(components.year ?? 0)-\(components.month ?? 0)",
                     forKey: "provider.openrouter.baseline.month")
        defaults.set(50.0, forKey: "provider.openrouter.baseline.usage")
        XCTAssertEqual(OpenRouterProvider.monthSpend(
            cumulative: 55,
            secretRevision: 0,
            now: now,
            defaults: defaults
        ), 5, accuracy: 0.001)

        // A replacement key starts a new measurement baseline, regardless of
        // the previous key's cumulative usage.
        XCTAssertEqual(OpenRouterProvider.monthSpend(
            cumulative: 200,
            secretRevision: 1,
            now: now,
            defaults: defaults
        ), 0, accuracy: 0.001)
        XCTAssertEqual(OpenRouterProvider.monthSpend(
            cumulative: 207.5,
            secretRevision: 1,
            now: now,
            defaults: defaults
        ), 7.5, accuracy: 0.001)

        let firstFingerprint = OpenRouterProvider.credentialFingerprint(
            key: "synthetic-key-a",
            revision: 0
        )
        let secondFingerprint = OpenRouterProvider.credentialFingerprint(
            key: "synthetic-key-b",
            revision: 1
        )
        XCTAssertNotNil(firstFingerprint)
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
        XCTAssertNil(OpenRouterProvider.credentialFingerprint(key: "", revision: 2))
    }

    func testOllamaUsesNewestExistingLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-ollama-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = directory.appendingPathComponent("older.log")
        let newer = directory.appendingPathComponent("newer.log")
        try Data("older".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )

        XCTAssertEqual(
            OllamaProvider.newestExistingLogPath(in: [older.path, newer.path]),
            newer.path
        )
        XCTAssertEqual(
            OllamaProvider.newestExistingLogPath(in: [newer.path, older.path]),
            newer.path,
            "selection must not depend on configured path order"
        )
    }

    func testOllamaFiltersUnrelatedDirectoryEvents() {
        let logs = ["/synthetic/logs/ollama.log", "/synthetic/app/server.log"]
        XCTAssertTrue(OllamaProvider.changesAffectLogs(
            ["/synthetic/logs/ollama.log"], logPaths: logs))
        XCTAssertTrue(OllamaProvider.changesAffectLogs(
            ["/synthetic/app"], logPaths: logs),
            "a directory-level event can represent log creation or rotation")
        XCTAssertFalse(OllamaProvider.changesAffectLogs(
            ["/synthetic/logs/unrelated.log"], logPaths: logs))
        XCTAssertFalse(OllamaProvider.changesAffectLogs([], logPaths: logs))
    }
}
