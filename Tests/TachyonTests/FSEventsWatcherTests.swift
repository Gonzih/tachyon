import XCTest
@testable import Tachyon

final class FSEventsWatcherTests: XCTestCase {
    func testMissingPathDoesNotPretendToBeWatched() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-missing-\(UUID().uuidString)").path
        let watcher = FSEventsWatcher(path: missing, onChange: { _ in })

        XCTAssertFalse(watcher.start())
        watcher.stop()
        watcher.stop()
    }

    func testLiveCallbackReceivesChangedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tachyon-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changed = expectation(description: "FSEvents callback")
        let file = directory.appendingPathComponent("synthetic-change.txt")
        let watcher = FSEventsWatcher(path: directory.path, latency: 0.05) { paths in
            if paths.contains(where: {
                URL(fileURLWithPath: $0).lastPathComponent == file.lastPathComponent
            }) {
                changed.fulfill()
            }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        try Data("synthetic".utf8).write(to: file)
        wait(for: [changed], timeout: 5)
    }
}
