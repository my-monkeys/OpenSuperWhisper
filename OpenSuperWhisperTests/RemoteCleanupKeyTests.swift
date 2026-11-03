import XCTest
@testable import OpenSuperWhisper

/// The API key field of the Remote cleanup (#273): which key it says is in place, and when
/// "Copy from Remote engine" has to ask first.
final class RemoteCleanupKeyTests: XCTestCase {

    func testTheSuffixIsTheLastFourCharacters() {
        XCTAssertEqual(RemoteCleanupKey.suffixHint(of: "sk-or-v1-abcdef1234"), "…1234")
    }

    func testNoKeyNoSuffix() {
        XCTAssertNil(RemoteCleanupKey.suffixHint(of: nil))
        XCTAssertNil(RemoteCleanupKey.suffixHint(of: ""))
    }

    func testAKeyTooShortToHideItsEndGivesNoSuffix() {
        XCTAssertNil(RemoteCleanupKey.suffixHint(of: "abcd123"))
        XCTAssertEqual(RemoteCleanupKey.suffixHint(of: "abcd1234"), "…1234")
    }

    func testCopyReplacingADifferentKeyAsksFirst() {
        XCTAssertTrue(RemoteCleanupKey.copyNeedsConfirmation(current: "sk-or-1", incoming: "gsk_2"))
        XCTAssertTrue(RemoteCleanupKey.copyNeedsConfirmation(current: "sk-or-1", incoming: ""),
                      "the engine has no key: copying would erase this one")
    }

    func testCopyIntoAnEmptyFieldOrWithTheSameKeyDoesNotAsk() {
        XCTAssertFalse(RemoteCleanupKey.copyNeedsConfirmation(current: "", incoming: "gsk_2"))
        XCTAssertFalse(RemoteCleanupKey.copyNeedsConfirmation(current: "gsk_2", incoming: "gsk_2"))
        XCTAssertFalse(RemoteCleanupKey.copyNeedsConfirmation(current: "", incoming: ""))
    }
}
