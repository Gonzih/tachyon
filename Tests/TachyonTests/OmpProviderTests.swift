import XCTest
import SQLite3
@testable import Tachyon

/// OmpProvider against a synthetic agent.db fixture, pointed at via OMP_HOME.
final class OmpProviderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("agent"), withIntermediateDirectories: true)
        setenv("OMP_HOME", home.path, 1)

        let dbPath = home.appendingPathComponent("agent/agent.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let now = Int(Date().timeIntervalSince1970)
        let statements = [
            """
            CREATE TABLE usage_cost_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL,
              provider TEXT NOT NULL, account_key TEXT NOT NULL, cost_usd REAL NOT NULL);
            """,
            """
            CREATE TABLE usage_history (
              recorded_at INTEGER, provider TEXT, account_key TEXT, email TEXT,
              account_id TEXT, limit_id TEXT, label TEXT, window_label TEXT,
              used_fraction REAL, status TEXT, resets_at INTEGER);
            """,
            // Today: two rows; last month: one row that must not count toward today.
            "INSERT INTO usage_cost_history VALUES (1, \(now - 60), 'anthropic', 'a', 1.25);",
            "INSERT INTO usage_cost_history VALUES (2, \(now - 120), 'openrouter', 'b', 0.75);",
            "INSERT INTO usage_cost_history VALUES (3, \(now - 40 * 86400), 'anthropic', 'a', 99.0);",
            // A fresh bounded window (65%) and a stale one that must be ignored.
            "INSERT INTO usage_history VALUES (\(now - 300), 'anthropic', 'a', 'x', 'y', 'weekly', 'Weekly', 'Weekly', 0.65, 'ok', \(now + 86400));",
            "INSERT INTO usage_history VALUES (\(now - 10 * 86400), 'openai', 'b', 'x', 'y', 'w', 'Old', 'Old', 0.9, 'ok', \(now - 5 * 86400));",
            """
            CREATE TABLE model_usage (
              model_key TEXT PRIMARY KEY, last_used_at INTEGER NOT NULL);
            """,
            // The newest row wins the footer, not insertion order.
            "INSERT INTO model_usage VALUES ('ollama/qwen2.5-coder:32b', \(now - 3600));",
            "INSERT INTO model_usage VALUES ('openrouter/poolside/laguna-s-2.1:free', \(now - 60));",
        ]
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }

        try "setupVersion: 1\nmodelRoles: \n  default: opencode-zen/nemotron-3-ultra-free\n"
            .write(to: home.appendingPathComponent("agent/config.yml"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        unsetenv("OMP_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    func testSnapshotSumsAndBoundedWindowWinsRing() async {
        let provider = OmpProvider()
        let presence = await provider.detect()
        XCTAssertEqual(presence, .ready)

        let state = await provider.snapshot()
        guard case .ok(let snapshot) = state else {
            return XCTFail("expected .ok, got \(state)")
        }
        // Real bounded window outranks spend for the ring.
        XCTAssertEqual(snapshot.primary.percentUsed, 65)
        XCTAssertTrue(snapshot.primary.label.contains("Anthropic"))

        let today = snapshot.windows.first { $0.label == "Today" }
        XCTAssertEqual(today?.spendUSD ?? -1, 2.0, accuracy: 0.001)
        // Synthetic periods carry no reset time — honesty rule.
        XCTAssertNil(today?.resetsAt)

        // The stale bounded window must not appear.
        XCTAssertFalse(snapshot.windows.contains { $0.label.contains("Old") })

        // Footer: last-used model from model_usage as "provider · model" —
        // the config default must NOT win while usage rows exist.
        XCTAssertEqual(snapshot.detail, "openrouter · laguna-s-2.1:free")
    }

    func testFooterFallsBackToConfigDefaultWithoutModelUsage() async {
        let dbPath = home.appendingPathComponent("agent/agent.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE model_usage;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let provider = OmpProvider()
        let state = await provider.snapshot()
        guard case .ok(let snapshot) = state else {
            return XCTFail("expected .ok, got \(state)")
        }
        XCTAssertEqual(snapshot.detail, "opencode-zen · nemotron-3-ultra-free")
    }

    func testBoundedWindowsPutWorstFirstAndParseISOReset() async {
        let dbPath = home.appendingPathComponent("agent/agent.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let now = Int(Date().timeIntervalSince1970)
        let insert = """
            INSERT INTO usage_history VALUES (
              \(now - 30), 'openai', 'c', NULL, NULL,
              'session', 'Session', 'Session', 0.82, 'ok',
              '2099-01-02T03:04:05.678Z');
            """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let state = await OmpProvider().snapshot()
        guard case .ok(let snapshot) = state else {
            return XCTFail("expected .ok, got \(state)")
        }
        XCTAssertEqual(snapshot.primary.percentUsed, 82)
        XCTAssertEqual(snapshot.windows.first, snapshot.primary)
        XCTAssertNotNil(snapshot.primary.resetsAt)
    }

    func testMissingDatabaseIsNotSignedIn() async {
        try? FileManager.default.removeItem(at: home.appendingPathComponent("agent/agent.db"))
        let provider = OmpProvider()
        let presence = await provider.detect()
        if case .notSignedIn = presence {} else {
            XCTFail("expected notSignedIn, got \(presence)")
        }
    }
}
