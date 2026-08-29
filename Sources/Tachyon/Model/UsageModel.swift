import AppKit
import Observation
import SwiftUI

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
    var presence: ProviderPresence = .notInstalled
    var state: ProviderState = .unavailable
    var enabled: Bool = true
    /// True until the first `snapshot()` completes.
    var awaitingFirstSnapshot: Bool = true

    /// Rings render only for enabled + ready providers.
    var isVisible: Bool { enabled && presence == .ready }

    var snapshot: UsageSnapshot? { state.snapshot }

    var ringPercent: Double? {
        guard !awaitingFirstSnapshot else { return nil }
        return state.snapshot?.primary.percentUsed
    }

    var ringSpend: Double? {
        guard !awaitingFirstSnapshot else { return nil }
        return state.snapshot?.primary.spendUSD
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
    @ObservationIgnored private var consecutiveFailures: [String: Int] = [:]
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    /// When a slot first went stale-without-fresh-data, so the demotion can expire.
    @ObservationIgnored private var staleSince: [String: Date] = [:]
    @ObservationIgnored private var refreshSignals: [String: RefreshSignal] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var onSlotsChanged: (() -> Void)?

    /// Consecutive failures before the poll interval stretches to 5 minutes.
    private static let failureThreshold = 3
    private static let backoffInterval: TimeInterval = 300
    /// How many poll intervals a demoted-to-stale reading stays on screen before
    /// the ring blanks to "–" (§3.1: a provider we cannot reach is not data).
    private static let staleGraceIntervals: Double = 3
    /// Re-run `detect()` every Nth poll so a sign-out is noticed (§2.4/§3.3).
    private static let redetectEveryNPolls = 10

    init(providers: [any UsageProvider] = ProviderRegistry.all) {
        self.providers = providers
        self.slots = providers.map { provider in
            ProviderSlot(
                id: provider.id,
                displayName: provider.displayName,
                shortName: provider.shortName,
                glyph: provider.glyph,
                isExperimental: provider.isExperimental,
                enabled: Settings.providerEnabled(provider.id)
            )
        }
    }

    // MARK: Lifecycle

    func start() {
        for provider in providers {
            let signal = RefreshSignal()
            refreshSignals[provider.id] = signal
            let id = provider.id
            Task { [weak self] in
                // Providers install file watchers here, never in `init`.
                await provider.start(onExternalChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        Log.model.debug("External change for \(id, privacy: .public); polling now")
                        self.resetBackoff(id)
                        let signal = self.refreshSignals[id]
                        Task { await signal?.fire() }
                    }
                })
                self?.beginPolling(provider, signal: signal)
            }
        }
        installSystemObservers()
    }

    /// One long-lived task per provider: detect until ready, then poll forever.
    /// `signal` collapses the sleep whenever something asks for a fresh read.
    private func beginPolling(_ provider: any UsageProvider, signal: RefreshSignal) {
        pollTasks[provider.id]?.cancel()
        pollTasks[provider.id] = Task { [weak self] in
            // Outer loop: a provider that signs out mid-run drops back into the
            // detect phase rather than polling a dead credential forever.
            while !Task.isCancelled {
                var presence = await provider.detect()
                guard let owner = self else { return }
                owner.apply(presence: presence, for: provider.id)

                // A user may sign in while we run, so keep re-detecting until ready.
                while !Task.isCancelled, presence != .ready {
                    await signal.wait(timeout: 60)
                    guard !Task.isCancelled else { return }
                    presence = await provider.detect()
                    guard let owner = self else { return }
                    owner.apply(presence: presence, for: provider.id)
                }
                guard !Task.isCancelled else { return }

                var pollsSinceDetect = 0
                var stillReady = true
                while !Task.isCancelled, stillReady {
                    let state = await provider.snapshot()
                    guard let self else { return }
                    self.apply(state: state, for: provider.id, pollInterval: provider.pollInterval)

                    // A user can sign out or uninstall while we run: re-detect
                    // periodically, and immediately whenever auth breaks, so the
                    // provider can fall back out of `.ready` (§2.4, §3.3).
                    pollsSinceDetect += 1
                    if state.isAuthError || pollsSinceDetect >= Self.redetectEveryNPolls {
                        pollsSinceDetect = 0
                        let current = await provider.detect()
                        self.apply(presence: current, for: provider.id)
                        stillReady = current == .ready
                        if !stillReady { break }
                    }

                    let interval = self.nextInterval(for: provider)
                    await signal.wait(timeout: interval)
                }
            }
        }
    }

    private func nextInterval(for provider: any UsageProvider) -> TimeInterval {
        // An armed backoff deadline is authoritative: sleep until it passes.
        if let until = backoffUntil[provider.id], until > Date() {
            return max(provider.pollInterval, until.timeIntervalSinceNow)
        }
        let failures = consecutiveFailures[provider.id] ?? 0
        return failures >= Self.failureThreshold ? Self.backoffInterval : provider.pollInterval
    }

    // MARK: State application

    private func apply(presence: ProviderPresence, for id: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        guard slots[index].presence != presence else { return }
        slots[index].presence = presence
        if presence != .ready {
            slots[index].state = .unavailable
            slots[index].awaitingFirstSnapshot = true
            resetStaleClock(id)
        }
        Log.model.info("\(id, privacy: .public) presence → \(String(describing: presence), privacy: .public)")
        onSlotsChanged?()
    }

    /// Applies a poll result.
    ///
    /// Failure counting is driven by the *fetch outcome*, not by the resulting UI
    /// state: only `.ok` means we reached the provider, so a `.stale` produced by
    /// a file fallback still counts as a failure and still arms the backoff
    /// (§2.1/§2.2). A demoted `.stale` also expires, so a provider that stays
    /// unreachable blanks to "–" instead of showing old numbers forever (§3.1).
    private func apply(state: ProviderState, for id: String, pollInterval: TimeInterval) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }

        var resolved = state
        switch state {
        case .ok:
            consecutiveFailures[id] = 0
            backoffUntil[id] = nil
            staleSince[id] = nil
        case .stale, .authError, .unavailable:
            let failures = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = failures
            if failures >= Self.failureThreshold {
                backoffUntil[id] = Date().addingTimeInterval(Self.backoffInterval)
            }

            if case .unavailable = state {
                // Keep the last good numbers visible, demoted to stale, rather
                // than blanking on a single blip — but only when the previous
                // reading was genuinely fresh, and only for a bounded window.
                let grace = pollInterval * Self.staleGraceIntervals
                if case .ok(let previous) = slots[index].state {
                    staleSince[id] = Date()
                    resolved = .stale(previous, asOf: previous.asOf)
                } else if case .stale(let previous, let asOf) = slots[index].state,
                          let since = staleSince[id],
                          Date().timeIntervalSince(since) < grace {
                    resolved = .stale(previous, asOf: asOf)
                } else {
                    // No fresh reading to fall back on, or the grace expired.
                    staleSince[id] = nil
                    resolved = .unavailable
                }
            } else {
                // Auth errors and provider-supplied stale readings pass through.
                if case .stale = state, staleSince[id] == nil { staleSince[id] = Date() }
                if case .authError = state { staleSince[id] = nil }
            }
        }

        slots[index].state = resolved
        slots[index].awaitingFirstSnapshot = false
        onSlotsChanged?()
    }

    private func resetBackoff(_ id: String) {
        consecutiveFailures[id] = 0
        backoffUntil[id] = nil
    }

    /// Providers whose fallback stream keeps serving old numbers still need the
    /// demotion clock to restart when the user asks for a manual refresh.
    private func resetStaleClock(_ id: String) {
        staleSince[id] = nil
    }

    // MARK: Commands

    /// Menu "Refresh now": re-poll everything and clear backoff.
    func refreshAll() {
        Log.model.info("Manual refresh")
        for provider in providers {
            resetBackoff(provider.id)
            resetStaleClock(provider.id)
            let signal = refreshSignals[provider.id]
            Task { await signal?.fire() }
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[index].enabled = enabled
        Settings.setProviderEnabled(enabled, for: id)
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
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.model.info("Wake — refreshing all providers")
                self?.refreshAll()
            }
        })
    }

    deinit {
        for task in pollTasks.values { task.cancel() }
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
    func wait(timeout: TimeInterval) async {
        if pending {
            pending = false
            return
        }
        let sleeper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, timeout)))
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // At most one caller waits per signal (the provider's own poll loop).
            if let existing = waiter {
                waiter = nil
                existing.resume()
            }
            waiter = continuation
        }
        sleeper.cancel()
        // A timeout that resumed us also set `pending` via `fire()`; clear it so
        // the next wait actually sleeps.
        pending = false
    }
}
