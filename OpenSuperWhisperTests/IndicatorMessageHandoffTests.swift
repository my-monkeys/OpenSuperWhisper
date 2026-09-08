import XCTest

@testable import OpenSuperWhisper

/// What happens to the bubble when the background pipeline has something to say.
///
/// Transcription runs after the recording is over, so its verdict arrives while the bubble is
/// still up saying "transcribing". Handing that message to a second bubble made the pill close
/// into the notch and reopen, which is the flicker between recording and "No speech detected".
final class IndicatorMessageHandoffTests: XCTestCase {

    private func mayTakeOver(_ state: RecordingState) -> Bool {
        IndicatorWindowManager.messageMayTakeOver(from: state)
    }

    /// The state the flicker was reported in. The clip has been handed off, the bubble is showing
    /// the spinner, and the answer lands in the same bubble.
    func testAMessageTakesOverTheTranscribingBubble() {
        XCTAssertTrue(mayTakeOver(.decoding))
    }

    /// Recordings are parallel, so an earlier clip can fail while the next take is being spoken.
    /// That message must not replace what the user is watching.
    func testALiveRecordingKeepsTheBubble() {
        XCTAssertFalse(mayTakeOver(.recording))
        XCTAssertFalse(mayTakeOver(.connecting))
    }

    /// A second message replaces the first rather than stacking a new bubble on it.
    func testOneMessageReplacesAnother() {
        XCTAssertTrue(mayTakeOver(.info("Copied")))
        XCTAssertTrue(mayTakeOver(.error("boom")))
        XCTAssertTrue(mayTakeOver(.busy))
    }

    func testAnIdleBubbleIsFreeToUse() {
        XCTAssertTrue(mayTakeOver(.idle))
    }
}
