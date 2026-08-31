import XCTest
@testable import Tachyon

final class SmokeTestTests: XCTestCase {
    @MainActor
    func testBlockingSmokeBridgePumpsMainActorWork() {
        let mainActorRan = DispatchSemaphore(value: 0)

        SmokeTest.waitForAsyncOperation {
            await MainActor.run {
                XCTAssertTrue(Thread.isMainThread)
                mainActorRan.signal()
            }
        }

        XCTAssertEqual(mainActorRan.wait(timeout: .now()), .success)
    }
}
