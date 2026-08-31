import Foundation
import SQLite3
import XCTest
@testable import Tachyon

@MainActor
final class ClaudeDesktopProviderTests: XCTestCase {
    private enum TestFailure: Error {
        case missingResponse
        case sessionLoad
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.withLock { value } }
        func set(_ newValue: Value) { lock.withLock { value = newValue } }
        func update<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&value) }
        }
    }

    private actor SessionLoader {
        private var sessions: [ClaudeDesktopProvider.SessionMaterial?]
        private(set) var count = 0

        init(_ sessions: [ClaudeDesktopProvider.SessionMaterial?]) {
            self.sessions = sessions
        }

        func load() -> ClaudeDesktopProvider.SessionMaterial? {
            count += 1
            guard sessions.count > 1 else { return sessions.first ?? nil }
            return sessions.removeFirst()
        }
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

    private actor FetchRecorder {
        private var responses: [String: [Usage.HTTPResult]]
        private(set) var paths: [String] = []
        private(set) var cookieHeaders: [String] = []

        init(_ responses: [String: [Usage.HTTPResult]]) {
            self.responses = responses
        }

        func fetch(_ url: URL, headers: [String: String]) throws -> Usage.HTTPResult {
            paths.append(url.path)
            cookieHeaders.append(headers["Cookie"] ?? "")
            guard var queue = responses[url.path], !queue.isEmpty else {
                throw TestFailure.missingResponse
            }
            let response = queue.removeFirst()
            responses[url.path] = queue
            return response
        }
    }

    private func cookie(
        _ name: String,
        _ value: String,
        host: String = ".claude.ai",
        path: String = "/",
        expiresAt: Date? = nil
    ) -> ClaudeDesktopProvider.Cookie {
        .init(
            host: host,
            path: path,
            name: name,
            value: value,
            expiresAt: expiresAt,
            isSecure: true
        )
    }

    private func material(
        session: String,
        organization: String,
        extraCookies: [ClaudeDesktopProvider.Cookie] = []
    ) -> ClaudeDesktopProvider.SessionMaterial {
        .init(
            cookies: .init(cookies: [
                cookie("sessionKey", session),
                cookie("lastActiveOrg", organization),
            ] + extraCookies),
            userAgent: "SyntheticDesktop/1.0"
        )
    }

    private func bootstrap(account: String, organization: String, plan: String = "claude_max") -> Data {
        Data("""
            {"account":{"uuid":"\(account)","memberships":[
              {"organization":{"uuid":"synthetic-api-pool","capabilities":["api"]}},
              {"organization":{"uuid":"\(organization)","capabilities":["chat","\(plan)"]}}
            ]}}
            """.utf8)
    }

    private static let usageBody = Data(#"{"five_hour":{"utilization":41}}"#.utf8)

    func testCookieCryptoMatchesIndependentVectorAndRejectsWrongDomain() {
        let key = ClaudeDesktopProvider.deriveCookieKey(password: Data("synthetic-password".utf8))
        XCTAssertEqual(key?.hex, "ad47d040c184e403f3afc7b04054ec52")

        let encrypted = Data(hex: """
            763130c3560208d5416d4395ccbaeda0fc5551185de44ad0932845bab0fb90e5
            56b854416d142bb8bdc3a8a8fbe6703df3ea9bd4847861edbfd9a3e6fd6db82f
            f3cbdf
            """)
        guard let key, let encrypted else { return XCTFail("synthetic vector malformed") }
        XCTAssertEqual(
            ClaudeDesktopProvider.decryptCookie(
                encrypted, host: ".claude.ai", schemaVersion: 24, key: key
            ),
            "synthetic-session"
        )
        XCTAssertNil(ClaudeDesktopProvider.decryptCookie(
            encrypted, host: "claude.ai", schemaVersion: 24, key: key
        ), "schema 24 cookies are cryptographically bound to their stored host")
        XCTAssertNil(ClaudeDesktopProvider.decryptCookie(
            Data("v12malformed".utf8), host: ".claude.ai", schemaVersion: 24, key: key
        ))
    }

    func testBootstrapVerifiesAccountAndActiveChatOrganization() {
        let data = Data("""
            {"account":{"uuid":"synthetic-account","memberships":[
              {"organization":{"uuid":"synthetic-api-pool","capabilities":["api"]}},
              {"organization":{"uuid":"synthetic-chat-pool","capabilities":["chat","claude_pro"]}}
            ]}}
            """.utf8)
        let identity = ClaudeDesktopProvider.decodeBootstrap(
            data,
            activeOrganization: "synthetic-chat-pool"
        )
        XCTAssertEqual(identity?.accountID, "synthetic-account")
        XCTAssertEqual(identity?.organizationID, "synthetic-chat-pool")
        XCTAssertEqual(identity?.subscription, "pro")
        XCTAssertNil(ClaudeDesktopProvider.decodeBootstrap(
            data,
            activeOrganization: "synthetic-unverified-pool"
        ))
        XCTAssertNil(ClaudeDesktopProvider.decodeBootstrap(
            Data(#"{"account":{"memberships":[]}}"#.utf8),
            activeOrganization: nil
        ))
    }

    func testCookieHeaderAppliesDomainPathExpiryAndSanitization() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jar = ClaudeDesktopProvider.CookieJar(cookies: [
            cookie("oversized", String(repeating: "x", count: 33 * 1024), path: "/api"),
            cookie("sessionKey", "synthetic-session"),
            cookie("cf_clearance", "synthetic-clearance", path: "/api"),
            cookie("expired", "synthetic-old", expiresAt: now.addingTimeInterval(-1)),
            cookie("wrongPath", "synthetic-other", path: "/settings"),
            cookie("unsafe", "synthetic;injected"),
            cookie("tabbed", "synthetic\tvalue"),
            cookie("unicode", "synthetic-☃"),
            cookie("quoted", "synthetic\"value"),
            cookie("comma", "synthetic,value"),
            cookie("backslash", "synthetic\\value"),
            cookie("nönascii", "synthetic-value"),
        ])
        let url = URL(string: "https://claude.ai/api/bootstrap")!
        let header = jar.header(for: url, now: now) ?? ""
        XCTAssertTrue(header.contains("sessionKey=synthetic-session"))
        XCTAssertTrue(header.contains("cf_clearance=synthetic-clearance"))
        XCTAssertFalse(header.contains("oversized="))
        XCTAssertFalse(header.contains("expired="))
        XCTAssertFalse(header.contains("wrongPath="))
        XCTAssertFalse(header.contains("unsafe="))
        XCTAssertFalse(header.contains("tabbed="))
        XCTAssertFalse(header.contains("unicode="))
        XCTAssertFalse(header.contains("quoted="))
        XCTAssertFalse(header.contains("comma="))
        XCTAssertFalse(header.contains("backslash="))
        XCTAssertFalse(header.contains("nönascii="))
        XCTAssertNil(jar.header(for: URL(string: "https://example.invalid/api")!, now: now))
    }

    func testUnsafeCookieFloodCannotHideSessionIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let junk = (0..<140).map { index in
            cookie("aaa\(index)", "synthetic;unsafe")
        }
        let material = ClaudeDesktopProvider.SessionMaterial(
            cookies: .init(cookies: junk + [
                cookie("sessionKey", "synthetic-session"),
                cookie("lastActiveOrg", "synthetic-pool"),
            ]),
            userAgent: "SyntheticDesktop/1.0"
        )
        let bootstrapURL = try XCTUnwrap(URL(string: "https://claude.ai/api/bootstrap"))

        XCTAssertEqual(
            material.selectionKey(now: now),
            .init(sessionKey: "synthetic-session", organizationHint: "synthetic-pool")
        )
        XCTAssertEqual(
            material.cookies.header(for: bootstrapURL, now: now),
            "lastActiveOrg=synthetic-pool; sessionKey=synthetic-session"
        )
    }

    func testSelectionIdentityUsesOnlyCookiesThatEnterRequestHeader() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let material = ClaudeDesktopProvider.SessionMaterial(
            cookies: .init(cookies: [
                cookie("sessionKey", "synthetic-expired-session",
                       expiresAt: now.addingTimeInterval(-1)),
                cookie("sessionKey", "synthetic-wrong-path", path: "/settings"),
                cookie("sessionKey", "synthetic-current-session"),
                cookie("lastActiveOrg", "synthetic-expired-pool",
                       expiresAt: now.addingTimeInterval(-1)),
                cookie("lastActiveOrg", "synthetic-current-pool"),
            ]),
            userAgent: "SyntheticDesktop/1.0"
        )
        let url = try XCTUnwrap(URL(string: "https://claude.ai/api/bootstrap"))
        let header = try XCTUnwrap(material.cookies.header(for: url, now: now))
        let selection = try XCTUnwrap(material.selectionKey(now: now))

        XCTAssertEqual(selection.sessionKey, "synthetic-current-session")
        XCTAssertEqual(selection.organizationHint, "synthetic-current-pool")
        XCTAssertTrue(header.contains("sessionKey=\(selection.sessionKey)"))
        XCTAssertFalse(header.contains("synthetic-expired-session"))
        XCTAssertFalse(header.contains("synthetic-wrong-path"))

        let ambiguous = ClaudeDesktopProvider.SessionMaterial(
            cookies: .init(cookies: material.cookies.cookies + [
                cookie("sessionKey", "synthetic-bootstrap-only", path: "/api/bootstrap"),
            ]),
            userAgent: material.userAgent
        )
        XCTAssertNil(
            ambiguous.selectionKey(now: now),
            "path-specific duplicate auth must not identify one request as another account"
        )

        let crossHostDuplicate = ClaudeDesktopProvider.SessionMaterial(
            cookies: .init(cookies: material.cookies.cookies + [
                cookie(
                    "sessionKey",
                    "synthetic-host-only-session",
                    host: "claude.ai"
                ),
            ]),
            userAgent: material.userAgent
        )
        XCTAssertNil(
            crossHostDuplicate.selectionKey(now: now),
            "distinct equal-path auth cookies have undefined server precedence"
        )
    }

    func testCookieDatabaseSelectionSkipsUnusableExistingCandidate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = ClaudeDesktopProvider.CookieJar(cookies: [
            cookie("sessionKey", "synthetic-stale-session",
                   expiresAt: now.addingTimeInterval(-1)),
        ])
        let current = ClaudeDesktopProvider.CookieJar(cookies: [
            cookie("sessionKey", "synthetic-current-session"),
            cookie("lastActiveOrg", "synthetic-current-pool"),
        ])
        var attempted: [String] = []

        let material = try XCTUnwrap(try ClaudeDesktopProvider.firstUsableSession(
            cookiePaths: ["/synthetic/Network/Cookies", "/synthetic/Cookies"],
            now: now,
            userAgent: "SyntheticDesktop/1.0",
            fileExists: { _ in true },
            loadCookieJar: { path in
                attempted.append(path)
                return path.hasSuffix("Network/Cookies") ? stale : current
            }
        ))

        XCTAssertEqual(attempted, ["/synthetic/Network/Cookies", "/synthetic/Cookies"])
        XCTAssertEqual(
            material.selectionKey(now: now)?.sessionKey,
            "synthetic-current-session"
        )
    }

    func testCookieDatabaseSelectionContinuesAfterCandidateReadFailure() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = ClaudeDesktopProvider.CookieJar(cookies: [
            cookie("sessionKey", "synthetic-current-session"),
            cookie("lastActiveOrg", "synthetic-current-pool"),
        ])
        var attempted: [String] = []

        let material = try XCTUnwrap(try ClaudeDesktopProvider.firstUsableSession(
            cookiePaths: ["/synthetic/Network/Cookies", "/synthetic/Cookies"],
            now: now,
            userAgent: "SyntheticDesktop/1.0",
            fileExists: { _ in true },
            loadCookieJar: { path in
                attempted.append(path)
                if path.hasSuffix("Network/Cookies") {
                    throw ClaudeDesktopProvider.ReadError.database
                }
                return current
            }
        ))

        XCTAssertEqual(attempted, ["/synthetic/Network/Cookies", "/synthetic/Cookies"])
        XCTAssertEqual(
            material.selectionKey(now: now)?.sessionKey,
            "synthetic-current-session"
        )
    }

    func testDesktopLocationsUseResolverThenKnownInstallLocations() {
        let home = "/synthetic/home"
        let resolved = URL(fileURLWithPath: "/Volumes/Synthetic/Claude.app")
        let system = URL(fileURLWithPath: "/Applications/Claude.app")
        let user = URL(fileURLWithPath: home + "/Applications/Claude.app")

        let resolvedLocations = ClaudeDesktopProvider.desktopLocations(
            homeDirectory: home,
            claudeUserDataDirectory: nil,
            resolveApplication: { resolved },
            fileExists: { [resolved.path, system.path, user.path].contains($0) }
        )
        XCTAssertEqual(resolvedLocations.applicationURL?.path, resolved.path)

        let systemLocations = ClaudeDesktopProvider.desktopLocations(
            homeDirectory: home,
            claudeUserDataDirectory: nil,
            resolveApplication: { nil },
            fileExists: { [system.path, user.path].contains($0) }
        )
        XCTAssertEqual(systemLocations.applicationURL?.path, system.path)

        let userLocations = ClaudeDesktopProvider.desktopLocations(
            homeDirectory: home,
            claudeUserDataDirectory: nil,
            resolveApplication: { nil },
            fileExists: { $0 == user.path }
        )
        XCTAssertEqual(userLocations.applicationURL?.path, user.path)
    }

    func testDesktopLocationsHonorOnlyAbsoluteOverrideAndDeduplicateRoots() {
        let home = "/synthetic/home"
        let expectedDefault = home + "/Library/Application Support/Claude"

        for invalidOverride: String? in [nil, "", "relative/profile", "~/profile"] {
            let locations = ClaudeDesktopProvider.desktopLocations(
                homeDirectory: home,
                claudeUserDataDirectory: invalidOverride,
                resolveApplication: { nil },
                fileExists: { _ in false }
            )
            XCTAssertEqual(locations.supportDirectories.map(\.path), [expectedDefault])
        }

        let override = "/Volumes/Synthetic/Claude Profile"
        let overridden = ClaudeDesktopProvider.desktopLocations(
            homeDirectory: home,
            claudeUserDataDirectory: override,
            resolveApplication: { nil },
            fileExists: { _ in false }
        )
        XCTAssertEqual(
            overridden.supportDirectories.map(\.path),
            [override, expectedDefault]
        )

        let duplicate = ClaudeDesktopProvider.desktopLocations(
            homeDirectory: home,
            claudeUserDataDirectory: expectedDefault + "/../Claude",
            resolveApplication: { nil },
            fileExists: { _ in false }
        )
        XCTAssertEqual(duplicate.supportDirectories.map(\.path), [expectedDefault])
    }

    func testReadOnlySQLiteLoaderHandlesPlainSyntheticCookieShape() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-claude-cookie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Cookies")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("fixture database did not open") }
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('version', '23');
            CREATE TABLE cookies (
              host_key TEXT, path TEXT, name TEXT, value TEXT,
              encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER
            );
            INSERT INTO cookies VALUES
              ('.claude.ai', '/', 'sessionKey', 'synthetic-sqlite-session', X'', 0, 1),
              ('.example.invalid', '/', 'unrelated', 'synthetic-other', X'', 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: databaseURL.path
        )

        let jar = try ClaudeDesktopProvider.loadCookieJar(at: databaseURL.path)
        XCTAssertEqual(
            jar?.value(
                named: "sessionKey",
                for: URL(string: "https://claude.ai/api/bootstrap")!,
                now: Date()
            ),
            "synthetic-sqlite-session"
        )
        XCTAssertEqual(jar?.cookies.count, 1)
    }

    func testPlaintextSessionSurvivesUnrelatedEncryptedRowWithoutKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-claude-cookie-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Cookies")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("fixture database did not open") }
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('version', '24');
            CREATE TABLE cookies (
              host_key TEXT, path TEXT, name TEXT, value TEXT,
              encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER
            );
            INSERT INTO cookies VALUES
              ('.claude.ai', '/', 'sessionKey', 'synthetic-plain-session', X'', 0, 1),
              ('.claude.ai', '/', 'cf_clearance', '', X'76313000', 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let keyLoads = LockedBox(0)
        let jar = try XCTUnwrap(ClaudeDesktopProvider.loadCookieJar(
            at: databaseURL.path,
            loadCookieKey: {
                keyLoads.update { count in
                    count += 1
                    return nil
                }
            }
        ))

        XCTAssertEqual(keyLoads.get(), 1)
        XCTAssertEqual(
            jar.value(
                named: "sessionKey",
                for: URL(string: "https://claude.ai/api/bootstrap")!,
                now: Date()
            ),
            "synthetic-plain-session"
        )
    }

    func testEncryptedOnlySessionWithoutKeyRemainsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-claude-cookie-encrypted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Cookies")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("fixture database did not open") }
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('version', '24');
            CREATE TABLE cookies (
              host_key TEXT, path TEXT, name TEXT, value TEXT,
              encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER
            );
            INSERT INTO cookies VALUES
              ('.claude.ai', '/', 'sessionKey', '', X'76313000', 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        XCTAssertThrowsError(try ClaudeDesktopProvider.loadCookieJar(
            at: databaseURL.path,
            loadCookieKey: { nil }
        )) { error in
            guard let readError = error as? ClaudeDesktopProvider.ReadError,
                  case .keychain = readError else {
                return XCTFail("expected a Safe Storage availability failure")
            }
        }
    }

    func testSQLiteJunkRowsCannotCrowdOutSessionIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-claude-cookie-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Cookies")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("fixture database did not open") }
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('version', '23');
            CREATE TABLE cookies (
              host_key TEXT, path TEXT, name TEXT, value TEXT,
              encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER
            );
            WITH RECURSIVE sequence(value) AS (
              SELECT 0 UNION ALL SELECT value + 1 FROM sequence WHERE value < 599
            )
            INSERT INTO cookies
              SELECT '.claude.ai', '/', 'aaa' || value, 'synthetic-junk', X'', 0, 1
              FROM sequence;
            INSERT INTO cookies VALUES
              ('.claude.ai', '/', 'sessionKey', 'synthetic-late-session', X'', 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let jar = try XCTUnwrap(ClaudeDesktopProvider.loadCookieJar(at: databaseURL.path))
        let material = ClaudeDesktopProvider.SessionMaterial(
            cookies: jar,
            userAgent: "SyntheticDesktop/1.0"
        )
        XCTAssertEqual(
            material.selectionKey(now: Date())?.sessionKey,
            "synthetic-late-session"
        )
        XCTAssertLessThanOrEqual(jar.cookies.count, 512)
    }

    func testDesktopPollUsesBootstrapIdentityAndCachesFingerprint() async {
        let session = material(
            session: "synthetic-desktop-a",
            organization: "synthetic-chat-a",
            extraCookies: [cookie("cf_clearance", "synthetic-clearance")]
        )
        let loader = SessionLoader([session])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-a",
                    organization: "synthetic-chat-a"
                )),
            ],
            "/api/organizations/synthetic-chat-a/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let state = await provider.snapshot()
        guard case .ok(let snapshot) = state else { return XCTFail("expected desktop usage") }
        XCTAssertEqual(snapshot.primary.percentUsed, 41)
        XCTAssertEqual(snapshot.detail, "Max")
        let fingerprint = await provider.accountFingerprint()
        XCTAssertNotNil(fingerprint)
        XCTAssertFalse(fingerprint?.contains("synthetic-account-a") ?? true)
        let paths = await recorder.paths
        XCTAssertEqual(paths, [
            "/api/bootstrap",
            "/api/organizations/synthetic-chat-a/usage",
        ], "identity should reuse the verified bootstrap result")
    }

    func testSnapshotFingerprintCannotRaceAheadToChangedDesktopSession() async {
        let first = material(session: "synthetic-desktop-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-desktop-b", organization: "synthetic-chat-b")
        let loader = SessionLoader([first, second])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-a", organization: "synthetic-chat-a"
                )),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b", organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-a/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 500, body: Data()),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))
        let expectedA = OpaqueAccountIdentity.fingerprint(
            namespace: "claude",
            components: ["synthetic-account-a", "synthetic-chat-a"]
        )
        let expectedB = OpaqueAccountIdentity.fingerprint(
            namespace: "claude",
            components: ["synthetic-account-b", "synthetic-chat-b"]
        )

        guard case .ok = await provider.snapshot() else {
            return XCTFail("expected the first Desktop snapshot")
        }
        await provider.fileChanged(provider.watchPaths[0] + "/Cookies")

        let firstFingerprint = await provider.accountFingerprint()
        let firstLoadCount = await loader.count
        XCTAssertEqual(firstFingerprint, expectedA)
        XCTAssertEqual(firstLoadCount, 1, "fingerprint read must not load the changed session")

        let secondSnapshot = await provider.snapshot()
        let secondFingerprint = await provider.accountFingerprint()
        XCTAssertEqual(secondSnapshot, .unavailable)
        XCTAssertEqual(
            secondFingerprint,
            expectedB,
            "a failed usage read may retain only the identity verified for that new attempt"
        )
        XCTAssertNotEqual(secondFingerprint, expectedA)
    }

    func testCancelledSessionLoadCannotOverwriteNewerDesktopAccountCache() async {
        let first = material(session: "synthetic-cancelled-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-current-b", organization: "synthetic-chat-b")
        let loader = SuspendedLoader<ClaudeDesktopProvider.SessionMaterial>()
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b",
                    organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 200, body: Self.usageBody),
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let cancelled = Task { await provider.reading() }
        await loader.waitForLoadCount(1)
        cancelled.cancel()

        let current = Task { await provider.reading() }
        await loader.waitForLoadCount(2)
        await loader.resumeLoad(at: 1, with: second)
        guard case .ok = await current.value.state else {
            return XCTFail("new Desktop account should complete")
        }

        await loader.resumeLoad(at: 0, with: first)
        _ = await cancelled.value
        guard case .ok = await provider.snapshot() else {
            return XCTFail("new Desktop account should remain cached")
        }
        let paths = await recorder.paths
        XCTAssertEqual(paths, [
            "/api/bootstrap",
            "/api/organizations/synthetic-chat-b/usage",
            "/api/organizations/synthetic-chat-b/usage",
        ])
    }

    func testDesktopAuthenticationRetryReloadsOnlyDesktopSession() async {
        let first = material(session: "synthetic-desktop-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-desktop-b", organization: "synthetic-chat-b")
        let loader = SessionLoader([first, second])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 401, body: Data()),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b",
                    organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        guard case .ok = await provider.snapshot() else {
            return XCTFail("a changed Desktop session should recover once")
        }
        let loadCount = await loader.count
        let headers = await recorder.cookieHeaders
        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(headers.first?.contains("sessionKey=synthetic-desktop-a") ?? false)
        XCTAssertTrue(headers.last?.contains("sessionKey=synthetic-desktop-b") ?? false)
    }

    func testDesktopAuthenticationRetryFallsThroughCookieDatabaseCandidates() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = material(session: "synthetic-network-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-legacy-b", organization: "synthetic-chat-b")
        let networkPath = "/synthetic/Network/Cookies"
        let legacyPath = "/synthetic/Cookies"
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 401, body: Data()),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b",
                    organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { excluded in
                try ClaudeDesktopProvider.firstUsableSession(
                    cookiePaths: [networkPath, legacyPath],
                    now: now,
                    userAgent: first.userAgent,
                    excluding: excluded,
                    fileExists: { _ in true },
                    loadCookieJar: { path in
                        path == networkPath ? first.cookies : second.cookies
                    }
                )
            },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { now }
        ))

        guard case .ok = await provider.snapshot() else {
            return XCTFail("a rejected current-layout database should fall through to legacy")
        }
        let headers = await recorder.cookieHeaders
        XCTAssertTrue(headers.first?.contains("sessionKey=synthetic-network-a") ?? false)
        XCTAssertTrue(headers.last?.contains("sessionKey=synthetic-legacy-b") ?? false)
    }

    func testDesktopReloadIOFailureIsUnavailableAndDoesNotPoisonSession() async {
        let session = material(session: "synthetic-recoverable", organization: "synthetic-chat")
        let loadCount = LockedBox(0)
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 401, body: Data()),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account",
                    organization: "synthetic-chat"
                )),
            ],
            "/api/organizations/synthetic-chat/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in
                let attempt = loadCount.update { count in
                    count += 1
                    return count
                }
                if attempt == 2 { throw TestFailure.sessionLoad }
                return session
            },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))

        let unavailable = await provider.snapshot()
        XCTAssertEqual(unavailable, .unavailable)
        guard case .ok = await provider.snapshot() else {
            return XCTFail("a transient reload failure must not reject the unchanged session")
        }
        XCTAssertEqual(loadCount.get(), 3)
    }

    func testDesktopLastGoodDoesNotCrossSessionOrOrganizationSwitch() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let first = material(session: "synthetic-desktop-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-desktop-b", organization: "synthetic-chat-b")
        let loader = SessionLoader([first, second])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-a",
                    organization: "synthetic-chat-a"
                )),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b",
                    organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-a/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 429, body: Data()),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { clock.get() }
        ))

        guard case .ok = await provider.snapshot() else { return XCTFail("expected baseline") }
        clock.set(clock.get().addingTimeInterval(61))
        let switched = await provider.snapshot()
        XCTAssertEqual(switched, .unavailable)
    }

    func testDesktopCacheRejectsBackwardClockJump() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let first = material(session: "synthetic-clock-a", organization: "synthetic-chat-a")
        let second = material(session: "synthetic-clock-b", organization: "synthetic-chat-b")
        let loader = SessionLoader([first, second])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-a", organization: "synthetic-chat-a"
                )),
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-b", organization: "synthetic-chat-b"
                )),
            ],
            "/api/organizations/synthetic-chat-a/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
            "/api/organizations/synthetic-chat-b/usage": [
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { clock.get() }
        ))

        _ = await provider.snapshot()
        clock.set(clock.get().addingTimeInterval(-1))
        _ = await provider.snapshot()

        let loadCount = await loader.count
        let paths = await recorder.paths
        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(paths.contains("/api/organizations/synthetic-chat-b/usage"))
    }

    func testDesktopCookieWatcherFiltersAndInvalidatesSessionCache() async {
        let session = material(session: "synthetic-watch", organization: "synthetic-chat-watch")
        let loader = SessionLoader([session, session])
        let recorder = FetchRecorder([
            "/api/bootstrap": [
                .init(status: 200, body: bootstrap(
                    account: "synthetic-account-watch", organization: "synthetic-chat-watch"
                )),
            ],
            "/api/organizations/synthetic-chat-watch/usage": [
                .init(status: 200, body: Self.usageBody),
                .init(status: 200, body: Self.usageBody),
                .init(status: 200, body: Self.usageBody),
            ],
        ])
        let provider = ClaudeDesktopProvider(dependencies: .init(
            isInstalled: { true },
            loadSession: { _ in await loader.load() },
            fetch: { url, headers in try await recorder.fetch(url, headers: headers) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ))
        let support = provider.watchPaths[0]
        XCTAssertFalse(provider.shouldRefresh(changedPaths: [support + "/config.json"]))
        XCTAssertTrue(provider.shouldRefresh(changedPaths: [support + "/Network/Cookies-wal"]))

        _ = await provider.snapshot()
        await provider.fileChanged(support + "/config.json")
        _ = await provider.snapshot()
        var loadCount = await loader.count
        XCTAssertEqual(loadCount, 1)

        await provider.fileChanged(support + "/Cookies")
        _ = await provider.snapshot()
        loadCount = await loader.count
        XCTAssertEqual(loadCount, 2)
    }

    func testDesktopUserAgentConstructionRejectsHeaderInjection() {
        XCTAssertEqual(
            ClaudeDesktopProvider.userAgent(
                claudeVersion: "1.2.3",
                chromeVersion: "146.0.7680.188",
                electronVersion: "41.3.0"
            ),
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Claude/1.2.3 Chrome/146.0.7680.188 Electron/41.3.0 Safari/537.36"
        )
        let rejected = ClaudeDesktopProvider.userAgent(
            claudeVersion: "1.2.3",
            chromeVersion: "146.0\r\nInjected: value",
            electronVersion: "41.3.0"
        )
        XCTAssertFalse(rejected.contains("Injected"))
    }
}

private extension Data {
    init?(hex: String) {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
