import XCTest
@testable import NoSleep

final class CaffeinateManagerTests: XCTestCase {
    func testNotifiesOnNaturalTimedExpiry() {
        XCTAssertTrue(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyWhenStoppedByUser() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true, duration: .twoHours))
    }

    func testNoNotifyOnStaleTokenFromRestart() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyForIndefinite() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .indefinite))
    }

    func testNoNotifyForNilDuration() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: nil))
    }
}
