@preconcurrency import CoreFoundation
import Foundation
import TachyonIPC

/// The app-side half of `tachyon status`. The callback runs on the main run
/// loop, reads only `UsageModel`'s already-cached slots, and returns promptly.
/// It deliberately has no route to a provider, a credential, or Settings.
@MainActor
final class TachyonStatusServer {
    private let status: () -> TachyonStatusResponse
    private let portName: String
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(
        portName: String = TachyonStatusProtocol.portName,
        status: @escaping () -> TachyonStatusResponse
    ) {
        self.portName = portName
        self.status = status
    }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            portName as CFString,
            tachyonStatusPortCallback,
            &context,
            &shouldFreeInfo
        ), !shouldFreeInfo.boolValue
        else {
            Log.app.error("Could not start CLI status service")
            return false
        }
        guard let source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMessagePortInvalidate(port)
            Log.app.error("Could not attach CLI status service to the main run loop")
            return false
        }

        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        Log.app.info("CLI status service started")
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port {
            CFMessagePortInvalidate(port)
        }
        source = nil
        port = nil
    }

    fileprivate func reply(messageID: Int32, requestData: Data) -> Unmanaged<CFData>? {
        guard messageID == TachyonStatusProtocol.statusMessageID,
              requestData.count <= TachyonStatusProtocol.maximumRequestBytes,
              let request = try? TachyonStatusProtocol.decode(TachyonStatusRequest.self, from: requestData),
              request.isSupported,
              let response = try? TachyonStatusProtocol.encode(status()),
              response.count <= TachyonStatusProtocol.maximumResponseBytes
        else { return nil }
        return Unmanaged.passRetained(response as CFData)
    }
}

private let tachyonStatusPortCallback: CFMessagePortCallBack = { _, messageID, data, info in
    guard let data, let info else { return nil }
    let requestData = data as Data
    let reference = StatusServerReference(info)
    return MainActor.assumeIsolated {
        reference.reply(messageID: messageID, requestData: requestData)
    }
}

/// `CFMessagePort` invokes a C callback, so Swift cannot infer its main-run-
/// loop guarantee. This wrapper makes the deliberately unretained context
/// explicit; the server removes and invalidates that source before it dies.
private struct StatusServerReference: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer

    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    @MainActor
    func reply(messageID: Int32, requestData: Data) -> Unmanaged<CFData>? {
        Unmanaged<TachyonStatusServer>.fromOpaque(pointer)
            .takeUnretainedValue()
            .reply(messageID: messageID, requestData: requestData)
    }
}

/// Serialization sits beside the model rather than the command-line target so
/// this is the only code path that knows about provider state. The transport
/// types intentionally omit account fingerprints and every credential shape.
@MainActor
enum TachyonStatusSnapshot {
    static func make(
        slots: [ProviderSlot],
        appVersion: String,
        now: Date = Date()
    ) -> TachyonStatusResponse {
        TachyonStatusResponse(
            generatedAt: timestamp(now),
            appVersion: appVersion,
            providers: slots.filter(\.enabled).map { providerStatus(for: $0, now: now) }
        )
    }

    private static func providerStatus(for slot: ProviderSlot, now: Date) -> TachyonProviderStatus {
        let snapshot = slot.snapshot
        return TachyonProviderStatus(
            id: slot.id,
            name: slot.shortName,
            source: slot.sourceLabel,
            presence: presence(for: slot.presence),
            state: state(for: slot.state),
            updatedAt: snapshot.map { timestamp($0.asOf) },
            detail: detail(for: slot, snapshot: snapshot),
            windows: (snapshot?.windows ?? []).map { window($0, now: now) }
        )
    }

    private static func presence(for presence: ProviderPresence) -> TachyonProviderPresence {
        switch presence {
        case .ready: .ready
        case .notInstalled: .notInstalled
        case .notSignedIn: .notSignedIn
        }
    }

    private static func state(for state: ProviderState) -> TachyonProviderState {
        switch state {
        case .ok: .current
        case .stale: .stale
        case .authError: .authError
        case .unavailable: .unavailable
        }
    }

    private static func detail(for slot: ProviderSlot, snapshot: UsageSnapshot?) -> String? {
        if let detail = snapshot?.detail, !detail.isEmpty { return detail }
        if let guidance = slot.state.authGuidance { return guidance }
        if case .notSignedIn(let guidance) = slot.presence { return guidance }
        return nil
    }

    private static func window(_ window: UsageWindow, now: Date) -> TachyonUsageWindow {
        TachyonUsageWindow(
            label: window.label,
            percentUsed: window.percentUsed,
            spendUSD: window.spendUSD,
            budgetUSD: window.budgetUSD,
            count: window.count,
            countUnit: window.countUnit,
            resetsAt: window.resetsAt.map(timestamp),
            windowSeconds: window.windowSeconds,
            displayValue: displayValue(for: window),
            resetText: ResetFormat.resetText(window.resetsAt, now: now)
        )
    }

    private static func displayValue(for window: UsageWindow) -> String {
        if let spend = window.spendUSD, let budget = window.budgetUSD {
            return "\(money(spend)) of \(money(budget))"
        }
        if let percent = window.percentUsed { return "\(Int(percent.rounded()))% Used" }
        if let spend = window.spendUSD { return "\(UsageWindow.formatSpend(spend)) spent" }
        if let count = window.count {
            return [String(count), window.countUnit].compactMap { $0 }.joined(separator: " ")
        }
        return "–"
    }

    private static func money(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "$\(Int(value))"
            : String(format: "$%.2f", value)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

extension UsageModel {
    func tachyonStatus(appVersion: String, now: Date = Date()) -> TachyonStatusResponse {
        TachyonStatusSnapshot.make(slots: slots, appVersion: appVersion, now: now)
    }
}
