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

    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let authGuidance = "Log in to Cursor"
    static let credentialCacheTTL: TimeInterval = 60
    private static let maxAuthBytes = 1024 * 1024

    struct Credential: Sendable {
        let accessToken: String
        let membership: String?
    }

    private struct CachedCredential: Sendable {
        let value: Credential
        let loadedAt: Date
    }

    /// Short-lived so an account switch is observed by the next scheduled
    /// poll while avoiding duplicate SQLite reads during detect + snapshot.
    private var cachedCredential: CachedCredential?

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
        return await snapshot(using: credential)
    }

    func reading() async -> ProviderReading {
        guard let credential = credential() else {
            return ProviderReading(
                state: .authError(Self.authGuidance),
                accountFingerprint: nil
            )
        }
        let state = await snapshot(using: credential)
        guard !Task.isCancelled else {
            return ProviderReading(state: .unavailable, accountFingerprint: nil)
        }
        return ProviderReading(
            state: state,
            accountFingerprint: Self.credentialFingerprint(
                accessToken: credential.accessToken,
                membership: credential.membership
            )
        )
    }

    private func snapshot(using credential: Credential) async -> ProviderState {
        do {
            let result = try await Usage.post(Self.usageURL, headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ], body: Data("{}".utf8))
            guard !Task.isCancelled else { return .unavailable }
            if result.status == 401 {
                // Token rotated or revoked; a fresh DB read is the only retry.
                if cachedCredential?.value.accessToken == credential.accessToken {
                    cachedCredential = nil
                }
                return .authError(Self.authGuidance)
            }
            guard (200..<300).contains(result.status) else {
                Log.provider.error("cursor usage HTTP \(result.status)")
                return .unavailable
            }
            guard let snapshot = Self.decode(result.body, credential: credential) else {
                Log.provider.error("cursor usage decode produced no usable window")
                return .unavailable
            }
            return .ok(snapshot)
        } catch {
            Log.provider.error("cursor usage request failed")
            return .unavailable
        }
    }

    static func credentialFingerprint(accessToken: String, membership: String?) -> String? {
        guard !accessToken.isEmpty else { return nil }
        var components = [accessToken]
        if let membership = membership?.trimmingCharacters(in: .whitespacesAndNewlines),
           !membership.isEmpty {
            components.append(membership)
        }
        return OpaqueAccountIdentity.fingerprint(
            namespace: "cursor-credential",
            components: components
        )
    }

    // MARK: - Decoding

    /// Payload (verified shape): `planUsage.{totalPercentUsed, autoPercentUsed,
    /// apiPercentUsed}`, `billingCycleStart/End`, `spendLimitUsage`, `enabled`.
    static func decode(_ data: Data, credential: Credential? = nil) -> UsageSnapshot? {
        let root = JSONValue.parse(data)
        let plan = root["planUsage"]

        guard let total = plan["totalPercentUsed"].double else { return nil }
        let cycleStart = periodDate(root["billingCycleStart"])
        let cycleEnd = periodDate(root["billingCycleEnd"])
        let cycleSeconds = periodDuration(start: cycleStart, end: cycleEnd)

        let primary = UsageWindow(
            label: "Billing cycle",
            percentUsed: total,
            resetsAt: cycleEnd,
            windowSeconds: cycleSeconds
        )
        var windows = [primary]

        // Sub-meters only when they carry real usage — same noise rule as Codex.
        if let auto = plan["autoPercentUsed"].double, auto >= 1 {
            windows.append(UsageWindow(
                label: "Auto",
                percentUsed: auto,
                resetsAt: cycleEnd,
                windowSeconds: cycleSeconds
            ))
        }
        if let api = plan["apiPercentUsed"].double, api >= 1 {
            windows.append(UsageWindow(
                label: "API",
                percentUsed: api,
                resetsAt: cycleEnd,
                windowSeconds: cycleSeconds
            ))
        }
        let spend = root["spendLimitUsage"]
        if let used = spend["individualUsed"].double,
           let limit = spend["individualLimit"].double, limit > 0 {
            windows.append(UsageWindow(
                label: "Spend limit",
                percentUsed: used / limit * 100,
                resetsAt: cycleEnd,
                windowSeconds: cycleSeconds
            ))
        }

        return UsageSnapshot(
            primary: primary,
            windows: windows,
            asOf: Date(),
            detail: detailText(credential: credential)
        )
    }

    /// Cursor has emitted ISO strings, epoch seconds, and decimal/string epoch
    /// milliseconds across clients. Keep this parser local: generic epochDate
    /// intentionally means seconds and must not silently reinterpret schemas.
    private static func periodDate(_ value: JSONValue) -> Date? {
        if let date = value.isoDate { return date }
        guard let raw = value.double, raw > 0 else { return nil }
        let maximum = Date.distantFuture.timeIntervalSince1970
        if raw <= maximum { return Date(timeIntervalSince1970: raw) }
        let seconds = raw / 1_000
        guard seconds <= maximum else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func periodDuration(start: Date?, end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let duration = end.timeIntervalSince(start)
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func detailText(credential: Credential?) -> String? {
        guard let membership = credential?.membership, !membership.isEmpty else { return nil }
        return membership.prefix(1).uppercased() + membership.dropFirst()
    }

    // MARK: - Credential chain

    private func credential(now: Date = Date()) -> Credential? {
        if let cached = cachedCredential,
           Self.credentialCacheIsFresh(loadedAt: cached.loadedAt, now: now) {
            return cached.value
        }
        // Never keep using a credential after its TTL if the source is now
        // missing or unreadable.
        cachedCredential = nil
        if let fromDB = Self.readStateDB() {
            cachedCredential = CachedCredential(value: fromDB, loadedAt: now)
            return fromDB
        }
        for path in Self.cliAuthPaths {
            guard let data = Usage.boundedFile(path: path, maximumBytes: Self.maxAuthBytes) else {
                continue
            }
            let json = JSONValue.parse(data)
            if let token = json["accessToken"].string, !token.isEmpty {
                let parsed = Credential(
                    accessToken: token,
                    membership: nil
                )
                cachedCredential = CachedCredential(value: parsed, loadedAt: now)
                return parsed
            }
        }
        return nil
    }

    static func credentialCacheIsFresh(loadedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(loadedAt)
        return age >= 0 && age < credentialCacheTTL
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
            membership: unquote(value(forKey: "cursorAuth/stripeMembershipType"))
        )
    }
}
