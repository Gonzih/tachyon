import Foundation

/// Read-only usage observed from Codex Desktop's own rollout stream.
///
/// Desktop and CLI may be signed into different accounts, so this provider
/// never reads CLI auth and never launches app-server with managed credentials.
/// A just-written exact-origin event is current for one poll interval; it then
/// becomes explicitly stale and expires after the shared three-poll bound.
/// Its bundle candidates, exact originator check, age transitions, and
/// unavailable/not-installed distinction form a portability/safety matrix.
/// Complexity refactors may extract those branches but must not delete a
/// candidate, weaken attribution, or collapse the distinct outcomes.
actor CodexDesktopProvider: UsageProvider {
    nonisolated let id = "codex-desktop"
    nonisolated let displayName = "Codex Desktop"
    nonisolated let shortName = "Codex"
    nonisolated let sourceLabel: String? = "Desktop"
    nonisolated let glyph = ProviderGlyph.codex
    nonisolated let pollInterval: TimeInterval = 60
    private static let guidance = "Run a turn in Codex Desktop"
    /// FSEvents normally delivers a completed turn within seconds. If no newer
    /// event arrives by the next scheduled poll, the observation is no longer
    /// current even though it remains useful as short-lived stale context.
    private static let currentObservationLifetime: TimeInterval = 60

    nonisolated let watchPaths: [String]
    private let sessionsPath: String
    private let executableResolver: @Sendable () async -> URL?
    private let now: @Sendable () -> Date

    init(
        sessionsPath: String = CodexProvider.defaultSessionsPath,
        executableResolver: @escaping @Sendable () async -> URL? = {
            CodexAppServerProbe.installedDesktopExecutableURL()
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionsPath = sessionsPath
        self.watchPaths = [sessionsPath]
        self.executableResolver = executableResolver
        self.now = now
    }

    func detect() async -> ProviderPresence {
        if observedState().snapshot != nil { return .ready }
        return await executableResolver() == nil
            ? .notInstalled
            : .notSignedIn(Self.guidance)
    }

    func snapshot() async -> ProviderState {
        observedState()
    }

    func reading() async -> ProviderReading {
        ProviderReading(state: await snapshot(), accountFingerprint: nil)
    }

    private func observedState() -> ProviderState {
        let current = now()
        guard let snapshot = CodexProvider.rolloutSnapshot(
            planType: nil,
            sessionsPath: sessionsPath,
            surface: .desktop,
            eligibleAt: current)
        else { return .unavailable }

        let age = current.timeIntervalSince(snapshot.asOf)
        return age < Self.currentObservationLifetime
            ? .ok(snapshot)
            : .stale(snapshot, asOf: snapshot.asOf)
    }
}
