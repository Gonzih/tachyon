import Foundation
import SQLite3

/// Cursor usage via its dashboard Connect-RPC endpoint.
///
/// Credential source: Cursor IDE's VS Code-style global storage — a SQLite
/// database whose `ItemTable` holds `cursorAuth/accessToken`. Read strictly
/// read-only (URI mode `ro`), so we can never disturb a running Cursor.
/// CLI fallback: `~/.cursor/auth.json`.
///
/// Endpoint + payload shape verified against this machine (structured
/// Connect 401 while logged out) and two independent implementations
/// (llmquota, CodexBar) — see kb/RESEARCH.md.
actor CursorProvider: UsageProvider {
    nonisolated let id = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let shortName = "Cursor"
    nonisolated let glyph = ProviderGlyph.cursor
    /// Billing-cycle usage moves slowly.
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let isExperimental = true

    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let authGuidance = "Log in to Cursor"

    struct Credential: Sendable {
        let accessToken: String
        let email: String?
        let membership: String?
    }

    private var cachedCredential: Credential?

    /// Kept so a transient failure degrades to `.stale` instead of blanking.
    private var lastGood: (snapshot: UsageSnapshot, at: Date)?

    // MARK: - Paths

    private static var stateDBPath: String {
        Usage.homePath("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private static var cliAuthPaths: [String] {
        [
            Usage.homePath("Library/Application Support/cursor/auth.json"),
            Usage.homePath(".cursor/auth.json"),
        ]
    }

    // MARK: - Presence

    func detect() async -> ProviderPresence {
        let installed = Usage.fileExists(Self.stateDBPath)
            || Usage.fileExists("/Applications/Cursor.app")
            || Self.cliAuthPaths.contains(where: Usage.fileExists)
        guard installed else { return .notInstalled }
        if credential() != nil { return .ready }
        return .notSignedIn(Self.authGuidance)
    }

    // MARK: - Snapshot

    func snapshot() async -> ProviderState {
        guard let credential = credential() else {
            return .authError(Self.authGuidance)
        }
        do {
            let result = try await Usage.post(Self.usageURL, headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ], body: Data("{}".utf8))
            if result.status == 401 {
                // Token rotated or revoked; a fresh DB read is the only retry.
                cachedCredential = nil
                return .authError(Self.authGuidance)
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("cursor usage HTTP \(result.status)")
                if let last = lastGood { return .stale(last.snapshot, asOf: last.at) }
                return .unavailable
            }
            guard let snapshot = Self.decode(result.body, credential: credential) else {
                Log.provider.error("cursor usage decode produced no usable window")
                return .unavailable
            }
            lastGood = (snapshot, Date())
            return .ok(snapshot)
        } catch {
            Log.provider.error("cursor usage request failed: \(error.localizedDescription, privacy: .public)")
            if let last = lastGood { return .stale(last.snapshot, asOf: last.at) }
            return .unavailable
        }
    }

    // MARK: - Decoding

    /// Payload (verified shape): `planUsage.{totalPercentUsed, autoPercentUsed,
    /// apiPercentUsed}`, `billingCycleStart/End`, `spendLimitUsage`, `enabled`.
    static func decode(_ data: Data, credential: Credential? = nil) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        let plan = root["planUsage"]

        guard let total = plan["totalPercentUsed"].double else { return nil }
        let cycleEnd = root["billingCycleEnd"].isoDate ?? root["billingCycleEnd"].epochDate

        let primary = UsageWindow(label: "Billing cycle", percentUsed: total, resetsAt: cycleEnd)
        var windows = [primary]

        // Sub-meters only when they carry real usage — same noise rule as Codex.
        if let auto = plan["autoPercentUsed"].double, auto >= 1 {
            windows.append(UsageWindow(label: "Auto", percentUsed: auto, resetsAt: cycleEnd))
        }
        if let api = plan["apiPercentUsed"].double, api >= 1 {
            windows.append(UsageWindow(label: "API", percentUsed: api, resetsAt: cycleEnd))
        }
        let spend = root["spendLimitUsage"]
        if let used = spend["individualUsed"].double,
           let limit = spend["individualLimit"].double, limit > 0 {
            windows.append(UsageWindow(
                label: "Spend limit",
                percentUsed: used / limit * 100,
                resetsAt: cycleEnd
            ))
        }

        return UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: Date(),
            detail: detailText(credential: credential)
        )
    }

    private static func detailText(credential: Credential?) -> String? {
        guard let membership = credential?.membership, !membership.isEmpty else { return nil }
        return membership.prefix(1).uppercased() + membership.dropFirst()
    }

    // MARK: - Credential chain

    private func credential() -> Credential? {
        if let cached = cachedCredential { return cached }
        if let fromDB = Self.readStateDB() {
            cachedCredential = fromDB
            return fromDB
        }
        for path in Self.cliAuthPaths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let json = JSONValue.parse(data)
            if let token = json["accessToken"].string, !token.isEmpty {
                let parsed = Credential(
                    accessToken: token,
                    email: json["email"].string,
                    membership: nil
                )
                cachedCredential = parsed
                return parsed
            }
        }
        return nil
    }

    /// Read-only SQLite read of Cursor's global storage. `immutable=1` is
    /// deliberately not used (the file *does* change); `mode=ro` + a busy
    /// timeout of 0 means a locked database degrades to nil, never blocks.
    private static func readStateDB() -> Credential? {
        guard Usage.fileExists(stateDBPath) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(stateDBPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        func value(forKey key: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }

        // Values are JSON-encoded strings ("\"token\"") or bare strings.
        func unquote(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            if let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded.isEmpty ? nil : decoded
            }
            return raw
        }

        guard let token = unquote(value(forKey: "cursorAuth/accessToken")) else { return nil }
        return Credential(
            accessToken: token,
            email: unquote(value(forKey: "cursorAuth/cachedEmail")),
            membership: unquote(value(forKey: "cursorAuth/stripeMembershipType"))
        )
    }
}
