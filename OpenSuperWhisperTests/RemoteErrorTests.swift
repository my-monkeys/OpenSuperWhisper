import XCTest
@testable import OpenSuperWhisper

/// Remote/cloud transcription failures are common and user-actionable — a wrong
/// or missing API key, an unreachable server, or an HTTP error — so the Remote
/// engine surfaces a descriptive `LocalizedError` instead of a bare generic
/// failure. This guards that each case yields a non-empty, on-point message.
final class RemoteErrorTests: XCTestCase {

    func testMissingKeyMentionsAKey() {
        let msg = RemoteError.missingAPIKey.errorDescription ?? ""
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("key"))
    }

    func testInvalidKeyHasAMessage() {
        XCTAssertFalse((RemoteError.invalidAPIKey.errorDescription ?? "").isEmpty)
    }

    func testAPIErrorIncludesStatusAndServerMessage() {
        let msg = RemoteError.api(500, "boom").errorDescription ?? ""
        XCTAssertTrue(msg.contains("500"))
        XCTAssertTrue(msg.contains("boom"))
    }

    func testNetworkErrorHasAMessage() {
        XCTAssertFalse((RemoteError.network(URLError(.timedOut)).errorDescription ?? "").isEmpty)
    }
}
