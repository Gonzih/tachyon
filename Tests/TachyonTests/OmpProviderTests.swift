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
        ]
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
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
