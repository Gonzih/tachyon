import XCTest
@testable import Tachyon

final class OllamaProviderTests: XCTestCase {
    private func gin(_ stamp: String, status: Int = 200, path: String = "/api/chat") -> String {
        "[GIN] \(stamp) | \(status) |      1.2s |       127.0.0.1 | POST     \"\(path)\""
    }

    func testCountsInferenceRequestsPerWindow() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        let now = formatter.date(from: "2026/08/28 - 22:30:00")!
        let lines = [
            gin("2026/08/28 - 22:11:14"),                      // past hour + today
            gin("2026/08/28 - 08:00:00"),                      // today only
            gin("2026/08/27 - 22:15:00"),                      // yesterday
            gin("2026/08/28 - 22:20:00", status: 404),         // error — skipped
            gin("2026/08/28 - 22:21:00", path: "/api/version"),// not inference
            gin("2026/08/28 - 22:22:00", path: "/v1/chat/completions"),
            "slot print_timing: id 0 | task 0 | noise",
        ]
        let counts = OllamaProvider.countRequests(lines: lines, now: now)
        XCTAssertEqual(counts.pastHour, 2)
        XCTAssertEqual(counts.today, 3)
    }

    func testGarbageLinesNeverCrash() {
        let counts = OllamaProvider.countRequests(
            lines: ["[GIN]", "[GIN] bad | x | y", "", "POST"], now: Date())
        XCTAssertEqual(counts, OllamaProvider.RequestCounts(pastHour: 0, today: 0))
    }

    func testSameDayFutureRequestIsExcludedFromBothWindows() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        let now = formatter.date(from: "2026/08/28 - 22:30:00")!

        let counts = OllamaProvider.countRequests(
            lines: [gin("2026/08/28 - 22:31:00")],
            now: now
        )

        XCTAssertEqual(counts, OllamaProvider.RequestCounts(pastHour: 0, today: 0))
    }

    func testCountWindowMeter() {
        let window = UsageWindow(label: "Requests · today", count: 42, unit: "requests", resetsAt: nil)
        XCTAssertNil(window.percentUsed)
        XCTAssertNil(window.spendUSD)
        XCTAssertEqual(window.count, 42)
        XCTAssertEqual(UsageWindow(label: "w", count: -3, unit: "x", resetsAt: nil).count, 0)
    }
}
