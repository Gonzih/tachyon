import AppKit
import Observation
import SwiftUI

/// Owns a block-based NotificationCenter token and makes teardown idempotent.
/// NotificationCenter retains these tokens, so relying on array destruction
/// alone would leak the observer after a model is released without `stop()`.
private final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func cancel() {
        let current = lock.withLock {
            defer { token = nil }
            return token
        }
        if let current { center.removeObserver(current) }
    }

    deinit { cancel() }
}

/// Usage color bands, half-open: [0,50) green · [50,70) yellow · [70,90) orange · [90,100] red.
enum UsageColor {
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let yellow = Color(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    static func band(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return green
        case ..<70: return yellow
        case ..<90: return orange
        default: return red
        }
    }

    static func nsBand(_ percent: Double) -> NSColor {
        switch percent {
        case ..<50: return NSColor(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
        case ..<70: return NSColor(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255, alpha: 1)
        case ..<90: return NSColor(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
        default: return NSColor(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
        }
    }
}

/// One provider's UI-facing slot: identity, presence, latest state.
struct ProviderSlot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let shortName: String
    let glyph: ProviderGlyph
    let isExperimental: Bool
    let providerSettings: [ProviderSetting]
    let about: String?
    let category: ProviderCategory
    let sourceLabel: String?
    /// Provider-specific UI grace only. Raw `.stale` still disables pace,
    /// dims conservative surfaces after this delay, and drives model backoff.
    let staleIndicatorDelay: TimeInterval
    var accountFingerprint: String?
    var presence: ProviderPresence = .notInstalled
    var state: ProviderState = .unavailable
    var enabled: Bool = true
    /// True until the first `snapshot()` completes.
    var lastPolled: Date?
    var awaitingFirstSnapshot: Bool = true

    /// Rings render only for enabled + ready providers.
    var isVisible: Bool { enabled && presence == .ready }

    var nameWithSource: String {
        guard let sourceLabel else { return shortName }
        return "\(shortName) \(sourceLabel)"
    }

    var snapshot: UsageSnapshot? { state.snapshot }

    var ringPercent: Double? {
        guard !awaitingFirstSnapshot else { return nil }
        return state.snapshot?.primary.percentUsed
    }

    /// Color-band input: `ringPercent` pace-escalated one band when the ring
    /// window is on pace to exhaust before reset. Numbers display raw.
    var ringBandPercent: Double? {
        guard !awaitingFirstSnapshot else { return nil }
        guard let primary = state.snapshot?.primary else { return nil }
        return PacePresentation(window: primary, isStale: state.isStale).bandPercent
    }

    /// Ring window on pace to exhaust before its reset → ring and shim pulse.
    var ringIsPaceHot: Bool {
        guard !awaitingFirstSnapshot, let primary = state.snapshot?.primary else { return false }
        return PacePresentation(window: primary, isStale: state.isStale).isHot
    }

    var ringSpend: Double? {
        guard !awaitingFirstSnapshot else { return nil }
        return state.snapshot?.primary.spendUSD
    }

    var ringCount: Int? {
        guard !awaitingFirstSnapshot else { return nil }
        return state.snapshot?.primary.count
    }

    /// A recent failed refresh can remain visually quiet for one provider-
    /// chosen interval while retaining stale semantics internally.
    func displaysStale(at date: Date = Date()) -> Bool {
        guard state.isStale else { return false }
        guard staleIndicatorDelay.isFinite, staleIndicatorDelay > 0,
              let staleSince = state.staleSince
        else { return true }
        let age = date.timeIntervalSince(staleSince)
        return !age.isFinite || age < 0 || age >= staleIndicatorDelay
    }

}

@MainActor
@Observable
final class UsageModel {
    // MARK: Stored state

    private(set) var slots: [ProviderSlot] = []
    /// Index of the ring the pointer is currently over, if any.
    var hoveredProviderID: String?

    // MARK: Non-observed internals

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]
    /// Invalidates work that outlives `stop()` (including a rapid stop/start).
    @ObservationIgnored private var pollRunGeneration: UInt64 = 0
    /// Invalidates an in-flight read across disable/re-enable of one source.
    @ObservationIgnored private var sourceGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var consecutiveFailures: [String: Int] = [:]
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    /// When a slot first went stale-without-fresh-data, so the demotion can expire.
    @ObservationIgnored private var staleSince: [String: Date] = [:]
    /// Source timestamps that already exhausted their grace period. A provider
    /// returning the same file/log record again must not re-arm another grace
    /// window after the UI has blanked it.
    @ObservationIgnored private var expiredStaleAsOf: [String: Date] = [:]
    /// Sources without a stored toggle receive one read-only detection pass.
    /// Its result seeds the preference; explicit user choices always win.
    @ObservationIgnored private var pendingInitialDetection: Set<String>
    /// Local UI deadlines are independent of network backoff: an old reading
    /// blanks on time without forcing an early provider request.
    @ObservationIgnored private var staleExpiryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshSignals: [String: RefreshSignal] = [:]
    @ObservationIgnored private var observers: [NotificationObservation] = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let persistProviderEnabled: (Bool, String) -> Void
    @ObservationIgnored var onSlotsChanged: (() -> Void)?

    /// Consecutive failures before the poll interval stretches to 5 minutes.
    private static let failureThreshold = 3
    private static let backoffInterval: TimeInterval = 300
    /// How many poll intervals a demoted-to-stale reading stays on screen before
    /// the ring blanks to "–" (§3.1: a provider we cannot reach is not data).
    private static let staleGraceIntervals: Double = 3
    /// Re-run `detect()` every Nth poll so a sign-out is noticed (§2.4/§3.3).
    private static let redetectEveryNPolls = 10

    init(
        providers: [any UsageProvider] = ProviderRegistry.all,
        providerPreference: (String) -> Bool? = Settings.providerPreference,
        persistProviderEnabled: @escaping (Bool, String) -> Void = {
            Settings.setProviderEnabled($0, for: $1)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.now = now
        self.persistProviderEnabled = persistProviderEnabled
        var preferences: [String: Bool] = [:]
        var pendingInitialDetection = Set<String>()
        for provider in providers {
            if let preference = providerPreference(provider.id) {
                preferences[provider.id] = preference
            } else {
                pendingInitialDetection.insert(provider.id)
            }
        }
        self.pendingInitialDetection = pendingInitialDetection
        self.slots = providers.map { provider in
            ProviderSlot(
                id: provider.id,
                displayName: provider.displayName,
                shortName: provider.shortName,
                glyph: provider.glyph,
                isExperimental: provider.isExperimental,
                providerSettings: provider.settings,
                about: provider.about,
                category: provider.category,
                sourceLabel: provider.sourceLabel,
                staleIndicatorDelay: provider.staleIndicatorDelay,
                accountFingerprint: nil,
                enabled: preferences[provider.id] ?? true
            )
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollRunGeneration &+= 1
        let runGeneration = pollRunGeneration
        for provider in providers {
            let signal = RefreshSignal()
            refreshSignals[provider.id] = signal
            beginPolling(provider, signal: signal, runGeneration: runGeneration)
            syncWatcher(for: provider)
        }
        installSystemObservers()
    }

    /// Ends every owned activity. Idempotent so AppDelegate, tests, and deinit
    /// can all use the same lifecycle without leaving file callbacks or long
    /// sleeps alive.
    func stop() {
        isRunning = false
        pollRunGeneration &+= 1
        let tasks = Array(pollTasks.values)
        let signals = Array(refreshSignals.values)
        pollTasks.removeAll()
        refreshSignals.removeAll()
        tasks.forEach { $0.cancel() }
        for task in staleExpiryTasks.values { task.cancel() }
        staleExpiryTasks.removeAll()
        for work in watcherRefreshTasks.values { work.task.cancel() }
        watcherRefreshTasks.removeAll()
        pendingWatcherPaths.removeAll()
        Task {
            for signal in signals { await signal.fire() }
        }

        for providerWatchers in watchers.values {
            for watcher in providerWatchers.values { watcher.stop() }
        }
        watchers.removeAll()

        for observer in observers { observer.cancel() }
        observers.removeAll()

        consecutiveFailures.removeAll()
        backoffUntil.removeAll()
        staleSince.removeAll()
        expiredStaleAsOf.removeAll()
        hoveredProviderID = nil
        var readingsChanged = false
        for index in slots.indices {
            if slots[index].state != .unavailable
                || slots[index].accountFingerprint != nil
                || slots[index].lastPolled != nil
                || slots[index].awaitingFirstSnapshot == false {
                readingsChanged = true
            }
            slots[index].state = .unavailable
            slots[index].accountFingerprint = nil
            slots[index].lastPolled = nil
            slots[index].awaitingFirstSnapshot = true
        }
        if readingsChanged { onSlotsChanged?() }
    }

    /// One long-lived task per provider: detect until ready, then poll forever.
    /// `signal` collapses the sleep whenever something asks for a fresh read.
    private func beginPolling(
        _ provider: any UsageProvider,
        signal: RefreshSignal,
        runGeneration: UInt64
    ) {
        pollTasks[provider.id]?.cancel()
        pollTasks[provider.id] = Task { [weak self] in
            var presence: ProviderPresence?
            var pollsSinceDetect = 0
            while !Task.isCancelled {
                guard self?.isCurrentRun(runGeneration) == true else { return }

                // Disabled means fully dormant: no credential prompt, file
                // access, network request, or watcher. The menu still exposes
                // an unchecked source row so it can wake detection explicitly.
                guard self?.isEnabled(provider.id) == true else {
                    await signal.wait(timeout: nil)
                    presence = nil
                    continue
                }

                if presence == nil {
                    switch await self?.detectPresence(
                        for: provider,
                        runGeneration: runGeneration
                    ) {
                    case .accepted(let detected):
                        presence = detected
                    case .disabled:
                        presence = nil
                        continue
                    case .superseded:
                        presence = nil
                        await signal.wait(timeout: nil)
                        continue
                    case .stopped, .none:
                        return
                    }
                }
                // Cancellation is covered at the loop boundary and, after an
                // awaited detection, by `canAcceptCompletedProviderResult`.
                guard presence == .ready else {
                    await signal.wait(timeout: 60)
                    presence = nil
                    continue
                }

                let sourceGeneration = self?.sourceGeneration(for: provider.id) ?? 0
                let reading = await provider.reading()
                guard self?.canAcceptCompletedProviderResult(
                        id: provider.id,
                        runGeneration: runGeneration,
                        sourceGeneration: sourceGeneration
                      ) == true
                else {
                    guard self?.isCurrentRun(runGeneration) == true else { return }
                    presence = nil
                    await signal.wait(timeout: nil)
                    continue
                }
                self?.apply(
                    state: reading.state,
                    accountFingerprint: reading.accountFingerprint,
                    for: provider.id,
                    pollInterval: Self.normalizedPollInterval(provider.pollInterval)
                )
                self?.syncWatcher(for: provider)

                guard let cycle = self?.pollCyclePlan(
                    after: reading.state,
                    provider: provider,
                    pollsSinceDetect: pollsSinceDetect
                ) else { return }
                pollsSinceDetect = cycle.pollsSinceDetect
                if cycle.shouldRedetect { presence = nil }
                await signal.wait(timeout: cycle.interval)
            }
        }
    }

    private enum DetectionCompletion {
        case accepted(ProviderPresence)
        case disabled
        case superseded
        case stopped
    }

    /// Keeps the initial-detection lifecycle explicit without nesting it in the
    /// polling loop. Every generation, enablement, persistence, and watcher
    /// guard is retained here; this extraction must not become permission to
    /// accept a late result or skip a first-seen source's one detection pass.
    private func detectPresence(
        for provider: any UsageProvider,
        runGeneration: UInt64
    ) async -> DetectionCompletion {
        let sourceGeneration = sourceGeneration(for: provider.id)
        let detected = await provider.detect()
        guard canAcceptCompletedProviderResult(
            id: provider.id,
            runGeneration: runGeneration,
            sourceGeneration: sourceGeneration
        ) else {
            return isCurrentRun(runGeneration) ? .superseded : .stopped
        }

        apply(presence: detected, for: provider.id)
        let remainsEnabled = completeInitialDetection(detected, for: provider.id)
        syncWatcher(for: provider)
        return remainsEnabled ? .accepted(detected) : .disabled
    }

    private struct PollCyclePlan {
        let pollsSinceDetect: Int
        let shouldRedetect: Bool
        let interval: TimeInterval
    }

    /// A user can sign out or uninstall while Tachyon runs. Auth failures and
    /// periodic checks re-detect on the bounded/backoff cadence; manual/file
    /// refresh still wakes the returned wait immediately.
    private func pollCyclePlan(
        after state: ProviderState,
        provider: any UsageProvider,
        pollsSinceDetect: Int
    ) -> PollCyclePlan {
        let nextCount = pollsSinceDetect + 1
        let shouldRedetect = state.isAuthError || nextCount >= Self.redetectEveryNPolls
        return PollCyclePlan(
            pollsSinceDetect: shouldRedetect ? 0 : nextCount,
            shouldRedetect: shouldRedetect,
            interval: nextInterval(for: provider)
        )
    }

    private func sourceGeneration(for id: String) -> UInt64 {
        sourceGenerations[id, default: 0]
    }

    private func isCurrentRun(_ generation: UInt64) -> Bool {
        isRunning && pollRunGeneration == generation
    }

    private func canAcceptProviderResult(
        id: String,
        runGeneration: UInt64,
        sourceGeneration: UInt64
    ) -> Bool {
        isCurrentRun(runGeneration)
            && isEnabled(id)
            && self.sourceGeneration(for: id) == sourceGeneration
    }

    private func canAcceptCompletedProviderResult(
        id: String,
        runGeneration: UInt64,
        sourceGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled && canAcceptProviderResult(
            id: id,
            runGeneration: runGeneration,
            sourceGeneration: sourceGeneration
        )
    }

    private func isEnabled(_ id: String) -> Bool {
        slots.first(where: { $0.id == id })?.enabled ?? false
    }

    private func nextInterval(for provider: any UsageProvider) -> TimeInterval {
        let pollInterval = Self.normalizedPollInterval(provider.pollInterval)
        // An armed backoff deadline is authoritative: sleep until it passes.
        let current = now()
        if let until = backoffUntil[provider.id], until > current {
            return max(pollInterval, until.timeIntervalSince(current))
        }
        let failures = consecutiveFailures[provider.id] ?? 0
        return failures >= Self.failureThreshold ? Self.backoffInterval : pollInterval
    }

    private static func normalizedPollInterval(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? min(value, 24 * 60 * 60) : 60
    }

    // MARK: State application

    private func apply(presence: ProviderPresence, for id: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        guard slots[index].presence != presence else { return }
        slots[index].presence = presence
        if presence != .ready {
            slots[index].state = .unavailable
            slots[index].awaitingFirstSnapshot = true
            slots[index].accountFingerprint = nil
            resetStaleClock(id)
        }
        let presenceLabel: String
        switch presence {
        case .notInstalled: presenceLabel = "not installed"
        case .notSignedIn: presenceLabel = "not signed in"
        case .ready: presenceLabel = "ready"
        }
        Log.model.info("\(id, privacy: .public) presence → \(presenceLabel, privacy: .public)")
        onSlotsChanged?()
    }

    /// First-seen providers are probed once and kept only when they already
    /// expose usable local state. This is per source, so a provider introduced
    /// by a later release gets the same zero-config classification without
    /// resetting any existing toggle.
    private func completeInitialDetection(
        _ presence: ProviderPresence,
        for id: String
    ) -> Bool {
        guard pendingInitialDetection.remove(id) != nil else { return isEnabled(id) }
        let enabled = presence == .ready
        persistProviderEnabled(enabled, id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return false }
        guard slots[index].enabled != enabled else { return enabled }
        slots[index].enabled = enabled
        if !enabled { cancelWatcherRefresh(for: id) }
        onSlotsChanged?()
        return enabled
    }

    /// Applies a poll result.
    ///
    /// Failure counting is driven by the *fetch outcome*, not by the resulting UI
    /// state: only `.ok` means we reached the provider, so a `.stale` produced by
    /// a file fallback still counts as a failure and still arms the backoff
    /// (§2.1/§2.2). A demoted `.stale` also expires, so a provider that stays
    /// unreachable blanks to "–" instead of showing old numbers forever (§3.1).
    private func apply(
        state: ProviderState,
        accountFingerprint: String?,
        for id: String,
        pollInterval: TimeInterval
    ) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }

        let current = now()
        resetForIdentityTransition(
            at: index,
            id: id,
            accountFingerprint: accountFingerprint
        )
        let resolved = resolve(
            state: state,
            previousState: slots[index].state,
            id: id,
            current: current,
            pollInterval: pollInterval
        )

        slots[index].accountFingerprint = accountFingerprint
        slots[index].state = resolved
        slots[index].awaitingFirstSnapshot = false
        slots[index].lastPolled = current
        syncStaleExpiry(for: id, state: resolved, pollInterval: pollInterval)
        onSlotsChanged?()
    }

    private func resetForIdentityTransition(
        at index: Int,
        id: String,
        accountFingerprint: String?
    ) {
        let previousFingerprint = slots[index].accountFingerprint
        guard previousFingerprint != accountFingerprint else { return }
        guard previousFingerprint != nil || accountFingerprint != nil else { return }

        // Any transition across a verified identity boundary is a hard data
        // boundary. Never attach the previous account's reading to a new or
        // temporarily unknown identity.
        slots[index].state = .unavailable
        staleSince[id] = nil
        expiredStaleAsOf[id] = nil
        consecutiveFailures[id] = 0
        backoffUntil[id] = nil
    }

    private func resolve(
        state: ProviderState,
        previousState: ProviderState,
        id: String,
        current: Date,
        pollInterval: TimeInterval
    ) -> ProviderState {
        switch state {
        case .ok:
            recordSuccessfulReading(id: id)
            return state
        case .unavailable:
            recordFailedReading(id: id, current: current)
            return resolveUnavailable(
                previousState: previousState,
                id: id,
                current: current,
                pollInterval: pollInterval
            )
        case .stale(let incoming, let asOf):
            recordFailedReading(id: id, current: current)
            return resolveIncomingStale(
                incoming,
                asOf: asOf,
                previousState: previousState,
                id: id,
                current: current,
                pollInterval: pollInterval
            )
        case .authError:
            recordFailedReading(id: id, current: current)
            staleSince[id] = nil
            return state
        }
    }

    private func recordSuccessfulReading(id: String) {
        consecutiveFailures[id] = 0
        backoffUntil[id] = nil
        staleSince[id] = nil
        // A successful live read establishes a new freshness boundary. If it
        // later fails, that verified reading deserves its own bounded grace.
        expiredStaleAsOf[id] = nil
    }

    private func recordFailedReading(id: String, current: Date) {
        let failures = (consecutiveFailures[id] ?? 0) + 1
        consecutiveFailures[id] = failures
        if failures >= Self.failureThreshold {
            backoffUntil[id] = current.addingTimeInterval(Self.backoffInterval)
        }
    }

    private func resolveUnavailable(
        previousState: ProviderState,
        id: String,
        current: Date,
        pollInterval: TimeInterval
    ) -> ProviderState {
        // Keep the last good numbers visible for one bounded grace window.
        let grace = pollInterval * Self.staleGraceIntervals
        switch previousState {
        case .ok(let previous):
            // Anchor fallback age to the last verified observation, not the
            // failure that noticed it. Otherwise sleep or a delayed poll can
            // give already-old data a brand-new grace window.
            let since = min(current, previous.asOf)
            guard current.timeIntervalSince(since) < grace else {
                rememberExpiredStale(id: id, asOf: previous.asOf)
                staleSince[id] = nil
                return .unavailable
            }
            staleSince[id] = since
            return .stale(previous, asOf: previous.asOf)
        case .stale(let previous, let asOf):
            guard let since = staleSince[id],
                  current.timeIntervalSince(since) < grace else {
                staleSince[id] = nil
                return .unavailable
            }
            return .stale(previous, asOf: asOf)
        case .authError, .unavailable:
            staleSince[id] = nil
            return .unavailable
        }
    }

    private func resolveIncomingStale(
        _ incoming: UsageSnapshot,
        asOf: Date,
        previousState: ProviderState,
        id: String,
        current: Date,
        pollInterval: TimeInterval
    ) -> ProviderState {
        // A provider fallback with an already-expired timestamp cannot re-arm
        // another grace window.
        if let expired = expiredStaleAsOf[id], incoming.asOf <= expired {
            staleSince[id] = nil
            return .unavailable
        }

        let previousAsOf = previousState.snapshot?.asOf
        if staleSince[id] == nil || incoming.asOf > (previousAsOf ?? .distantPast) {
            staleSince[id] = min(current, asOf)
        }
        let grace = pollInterval * Self.staleGraceIntervals
        guard let since = staleSince[id],
              current.timeIntervalSince(since) >= grace else {
            return .stale(incoming, asOf: asOf)
        }

        rememberExpiredStale(id: id, asOf: incoming.asOf)
        staleSince[id] = nil
        return .unavailable
    }

    private func resetBackoff(_ id: String) {
        consecutiveFailures[id] = 0
        backoffUntil[id] = nil
    }

    /// Reset when a source/account lifecycle changes. A manual refresh does not
    /// call this: pressing Refresh must never extend an old fallback's TTL.
    private func resetStaleClock(_ id: String) {
        staleSince[id] = nil
        expiredStaleAsOf[id] = nil
        staleExpiryTasks.removeValue(forKey: id)?.cancel()
    }

    private func rememberExpiredStale(id: String, asOf: Date) {
        expiredStaleAsOf[id] = max(expiredStaleAsOf[id] ?? .distantPast, asOf)
    }

    private func syncStaleExpiry(
        for id: String,
        state: ProviderState,
        pollInterval: TimeInterval
    ) {
        staleExpiryTasks.removeValue(forKey: id)?.cancel()
        guard state.isStale, let since = staleSince[id], isRunning else { return }

        let grace = Self.staleGrace(for: pollInterval)
        let deadline = since.addingTimeInterval(grace)
        let delay = max(0, deadline.timeIntervalSince(now()))
        staleExpiryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expireStale(
                id: id,
                expectedSince: since,
                pollInterval: pollInterval
            )
        }
    }

    private func expireStale(
        id: String,
        expectedSince: Date,
        pollInterval: TimeInterval
    ) {
        guard isRunning, isEnabled(id), staleSince[id] == expectedSince,
              let index = slots.firstIndex(where: { $0.id == id }),
              slots[index].state.isStale
        else { return }

        let deadline = expectedSince.addingTimeInterval(Self.staleGrace(for: pollInterval))
        guard now() >= deadline else {
            // A wall-clock correction moved the deadline forward. Re-arm from
            // the corrected clock rather than expiring early.
            syncStaleExpiry(for: id, state: slots[index].state, pollInterval: pollInterval)
            return
        }
        if let asOf = slots[index].state.snapshot?.asOf {
            rememberExpiredStale(id: id, asOf: asOf)
        }
        staleSince[id] = nil
        staleExpiryTasks[id] = nil
        slots[index].state = .unavailable
        onSlotsChanged?()
    }

    private static func staleGrace(for pollInterval: TimeInterval) -> TimeInterval {
        let grace = pollInterval * staleGraceIntervals
        return grace.isFinite && grace > 0 ? grace : backoffInterval
    }

    // MARK: Commands

    /// Menu "Refresh now": re-poll everything and clear backoff.
    /// Per-provider immediate re-poll — used by the Settings window after a
    /// value changes so the ring reflects it without waiting out the interval.
    func refresh(id: String) {
        resetBackoff(id)
        let signal = refreshSignals[id]
        Task { await signal?.fire() }
    }

    func refreshAll() {
        Log.model.info("Manual refresh")
        for provider in providers {
            refresh(id: provider.id)
        }
    }

    // MARK: File watching (model-owned, declarative)

    @ObservationIgnored private var watchers: [String: [String: FSEventsWatcher]] = [:]
    private struct WatcherRefreshWork {
        let runGeneration: UInt64
        let sourceGeneration: UInt64
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var watcherRefreshTasks: [String: WatcherRefreshWork] = [:]
    @ObservationIgnored private var pendingWatcherPaths: [String: Set<String>] = [:]

    /// FSEvents can batch unrelated and relevant paths together. Preserve the
    /// batch-level provider decision, but pass cache invalidation a path that
    /// the provider itself accepts whenever one exists.
    static func refreshPath(
        for provider: any UsageProvider,
        changedPaths: [String]
    ) -> String? {
        guard provider.shouldRefresh(changedPaths: changedPaths) else { return nil }
        return changedPaths.first(where: { provider.shouldRefresh(changedPaths: [$0]) })
            ?? changedPaths.first
    }

    /// Watch a provider's declared paths iff it is enabled and declares any.
    private func syncWatcher(for provider: any UsageProvider) {
        let id = provider.id
        let wantsWatch = provider.watchPaths.isEmpty == false
            && isRunning
            && (slots.first(where: { $0.id == id })?.enabled ?? false)

        if !wantsWatch {
            watchers[id]?.values.forEach { $0.stop() }
            watchers[id] = nil
            cancelWatcherRefresh(for: id)
            return
        }

        let desired = Set(provider.watchPaths)
        var active = watchers[id] ?? [:]
        for path in active.keys.filter({ !desired.contains($0) }) {
            active.removeValue(forKey: path)?.stop()
        }

        for path in desired where active[path] == nil {
            let runGeneration = pollRunGeneration
            let sourceGeneration = sourceGeneration(for: id)
            let watcher = FSEventsWatcher(path: path, latency: 2.0, onChange: { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.enqueueWatcherRefresh(
                        provider: provider,
                        id: id,
                        changedPaths: paths.isEmpty ? [path] : paths,
                        runGeneration: runGeneration,
                        sourceGeneration: sourceGeneration
                    )
                }
            })
            if watcher.start() { active[path] = watcher }
        }
        watchers[id] = active.isEmpty ? nil : active
    }

    /// Testable entry to the same generation-checked coalescer used by live
    /// FSEvents callbacks. One path is processed once per burst and all cache
    /// invalidations finish before a single poll signal is fired.
    func handleWatchChange(id: String, changedPaths: [String]) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        enqueueWatcherRefresh(
            provider: provider,
            id: id,
            changedPaths: changedPaths,
            runGeneration: pollRunGeneration,
            sourceGeneration: sourceGeneration(for: id)
        )
    }

    private func enqueueWatcherRefresh(
        provider: any UsageProvider,
        id: String,
        changedPaths: [String],
        runGeneration: UInt64,
        sourceGeneration: UInt64
    ) {
        guard canAcceptProviderResult(
            id: id,
            runGeneration: runGeneration,
            sourceGeneration: sourceGeneration
        ), let changedPath = Self.refreshPath(for: provider, changedPaths: changedPaths)
        else { return }

        pendingWatcherPaths[id, default: []].insert(changedPath)
        if let work = watcherRefreshTasks[id] {
            if work.runGeneration == runGeneration,
               work.sourceGeneration == sourceGeneration {
                return
            }
            work.task.cancel()
            watcherRefreshTasks[id] = nil
        }

        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  let changedPath = self?.takePendingWatcherPath(for: id) {
                await provider.fileChanged(changedPath)
                guard !Task.isCancelled,
                      self?.canAcceptProviderResult(
                        id: id,
                        runGeneration: runGeneration,
                        sourceGeneration: sourceGeneration
                      ) == true
                else { break }
            }

            guard !Task.isCancelled,
                  self?.canAcceptProviderResult(
                    id: id,
                    runGeneration: runGeneration,
                    sourceGeneration: sourceGeneration
                  ) == true
            else {
                self?.finishWatcherRefresh(
                    id: id,
                    runGeneration: runGeneration,
                    sourceGeneration: sourceGeneration
                )
                return
            }

            Log.model.debug("Watched change for \(id, privacy: .public); polling now")
            self?.refresh(id: id)
            self?.finishWatcherRefresh(
                id: id,
                runGeneration: runGeneration,
                sourceGeneration: sourceGeneration
            )
        }
        watcherRefreshTasks[id] = WatcherRefreshWork(
            runGeneration: runGeneration,
            sourceGeneration: sourceGeneration,
            task: task
        )
    }

    private func takePendingWatcherPath(for id: String) -> String? {
        guard var paths = pendingWatcherPaths[id], let path = paths.popFirst() else {
            pendingWatcherPaths[id] = nil
            return nil
        }
        pendingWatcherPaths[id] = paths.isEmpty ? nil : paths
        return path
    }

    private func finishWatcherRefresh(
        id: String,
        runGeneration: UInt64,
        sourceGeneration: UInt64
    ) {
        guard let work = watcherRefreshTasks[id],
              work.runGeneration == runGeneration,
              work.sourceGeneration == sourceGeneration
        else { return }
        watcherRefreshTasks[id] = nil
        pendingWatcherPaths[id] = nil
    }

    private func cancelWatcherRefresh(for id: String) {
        watcherRefreshTasks.removeValue(forKey: id)?.task.cancel()
        pendingWatcherPaths[id] = nil
    }

    /// Internal lifecycle diagnostic used by deterministic scheduler tests.
    func activeWatcherCount(for id: String) -> Int {
        watchers[id]?.count ?? 0
    }

    func activeWatcherRefreshCount(for id: String) -> Int {
        watcherRefreshTasks[id] == nil ? 0 : 1
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let wasPending = pendingInitialDetection.remove(id) != nil
        guard slots[index].enabled != enabled else {
            if wasPending { persistProviderEnabled(enabled, id) }
            return
        }
        sourceGenerations[id, default: 0] &+= 1
        slots[index].enabled = enabled
        persistProviderEnabled(enabled, id)
        resetBackoff(id)
        resetStaleClock(id)
        if enabled {
            // Do not flash a previous account's cached reading while the newly
            // enabled source revalidates its credential and identity.
            slots[index].state = .unavailable
            slots[index].awaitingFirstSnapshot = true
            slots[index].accountFingerprint = nil
            slots[index].lastPolled = nil
        } else {
            cancelWatcherRefresh(for: id)
        }
        if let provider = providers.first(where: { $0.id == id }) {
            syncWatcher(for: provider)
        }
        let signal = refreshSignals[id]
        Task { await signal?.fire() }
        onSlotsChanged?()
    }

    // MARK: Derived views

    /// Slots that get a ring, in registry order.
    var visibleSlots: [ProviderSlot] {
        slots.filter(\.isVisible)
    }

    func slot(id: String) -> ProviderSlot? {
        slots.first { $0.id == id }
    }

    // MARK: System notifications

    private func installSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.model.info("Wake — refreshing all providers")
                self?.refreshAll()
            }
        }
        observers.append(NotificationObservation(center: workspace, token: token))
    }

    deinit {
        let signals = Array(refreshSignals.values)
        for task in pollTasks.values { task.cancel() }
        for task in staleExpiryTasks.values { task.cancel() }
        for work in watcherRefreshTasks.values { work.task.cancel() }
        for providerWatchers in watchers.values {
            for watcher in providerWatchers.values { watcher.stop() }
        }
        for observer in observers { observer.cancel() }
        Task {
            for signal in signals { await signal.fire() }
        }
    }
}

/// A one-shot wake-up channel: `wait(timeout:)` returns early when `fire()`
/// is called, which is how FSEvents and "Refresh now" short-circuit a sleep.
actor RefreshSignal {
    private var waiter: CheckedContinuation<Void, Never>?
    /// A `fire()` that arrived while nobody was waiting is not lost.
    private var pending = false

    func fire() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pending = true
        }
    }

    /// Sleeps up to `timeout` seconds, or until `fire()` — whichever comes first.
    func wait(timeout: TimeInterval?) async {
        if pending {
            pending = false
            return
        }
        let sleeper: Task<Void, Never>? = timeout.map { timeout in
            let seconds = timeout.isFinite && timeout > 0
                ? min(max(1, timeout), 24 * 60 * 60)
                : 60
            return Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.fire()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // At most one caller waits per signal (the provider's own poll loop).
            if let existing = waiter {
                waiter = nil
                existing.resume()
            }
            waiter = continuation
        }
        sleeper?.cancel()
        // A timeout that resumed us also set `pending` via `fire()`; clear it so
        // the next wait actually sleeps.
        pending = false
    }
}
