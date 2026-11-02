import XCTest
import OpenSuperWhisperCore
@testable import OpenSuperWhisper

/// What the Settings are told about the last cleanup of this launch (#264).
@MainActor
final class CleanupSessionStatusTests: XCTestCase {

    private let failed = CleanupOutcome(text: "raw", status: .failed(model: "m", reason: "401 Invalid API key"))
    private let cleaned = CleanupOutcome(text: "ok", status: .cleaned(model: "m"))
    private let notRun = CleanupOutcome(text: "raw", status: .notRun)

    override func tearDown() async throws {
        CleanupSessionStatus.shared.record(cleaned)
    }

    func testAFailureIsKeptWithItsReasonAndTime() {
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        CleanupSessionStatus.shared.record(failed, at: when)
        XCTAssertEqual(CleanupSessionStatus.shared.lastFailure,
                       .init(model: "m", reason: "401 Invalid API key", date: when))
    }

    func testASuccessClearsIt() {
        CleanupSessionStatus.shared.record(failed)
        CleanupSessionStatus.shared.record(cleaned)
        XCTAssertNil(CleanupSessionStatus.shared.lastFailure)
    }

    /// A dictation with cleanup off proves nothing about a cleanup that was failing.
    func testADictationWithoutAPassLeavesItAlone() {
        CleanupSessionStatus.shared.record(failed)
        CleanupSessionStatus.shared.record(notRun)
        XCTAssertEqual(CleanupSessionStatus.shared.lastFailure?.reason, "401 Invalid API key")
    }
}
