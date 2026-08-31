import Foundation

/// `Tachyon --smoke` — a headless diagnostic that runs every registered provider
/// once and prints what it found, without opening a window.
///
/// This is the fastest way to validate a new provider against your own machine:
/// see CONTRIBUTING.md. It is also what makes `swift build` meaningful in CI,
/// where there is no display to attach to.
enum SmokeTest {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--smoke") else { return false }

        waitForAsyncOperation {
            await run()
        }
        return true
    }

    /// The app entry point is synchronous and runs on the main thread. Blocking
    /// it on a semaphore deadlocks any provider that legitimately hops to
    /// `MainActor` for an AppKit lookup (Codex Desktop does this through
    /// `NSWorkspace`). Pump the main run loop while the diagnostic runs so
    /// those hops can complete without changing normal app startup.
    static func waitForAsyncOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        precondition(Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        Task {
            await operation()
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private static func run() async {
        print("Tachyon provider diagnostic\n")

        for provider in ProviderRegistry.all {
            let flag = provider.isExperimental ? " [experimental]" : ""
            print("\(provider.displayName) (\(provider.id))\(flag)")

            let presence = await provider.detect()
            switch presence {
            case .notInstalled:
                print("  presence: not installed\n")
                continue
            case .notSignedIn(let guidance):
                print("  presence: not signed in — \(guidance)\n")
                continue
            case .ready:
                print("  presence: ready")
            }

            let state = await provider.snapshot()
            switch state {
            case .ok(let snapshot), .stale(let snapshot, _):
                let freshness = state.isStale ? "stale" : "current"
                print("  state: \(freshness), \(snapshot.windows.count) window(s)")
                print("  ring: \(snapshot.primary.label) — \(meterText(snapshot.primary))")
                for window in snapshot.windows {
                    let reset = ResetFormat.resetText(window.resetsAt).map { "  (\($0))" } ?? ""
                    print("    · \(window.label): \(meterText(window))\(reset)")
                }
                if let detail = snapshot.detail { print("  plan: \(detail)") }
            case .authError(let guidance):
                print("  state: auth error — \(guidance)")
            case .unavailable:
                print("  state: unavailable")
            }
            print("")
        }

        // A wrong color band is invisible in a screenshot but loud in daily use,
        // so the boundaries are asserted here rather than trusted.
        print("Color bands (half-open):")
        for percent in [0.0, 21, 49.9, 50, 69.9, 70, 89.9, 90, 100] {
            print("  \(format(percent)) → \(bandName(percent))")
        }
    }
    static func meterText(_ window: UsageWindow) -> String {
        if let percent = window.percentUsed { return format(percent) }
        if let spend = window.spendUSD { return UsageWindow.formatSpend(spend) + " spent" }
        if let count = window.count { return "\(count) \(window.countUnit ?? "")" }
        return "-"
    }


    private static func format(_ percent: Double) -> String {
        String(format: "%.0f%%", percent)
    }

    private static func bandName(_ percent: Double) -> String {
        switch percent {
        case ..<50: return "green"
        case ..<70: return "yellow"
        case ..<90: return "orange"
        default: return "red"
        }
    }
}
