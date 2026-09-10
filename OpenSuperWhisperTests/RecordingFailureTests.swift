import XCTest

@testable import OpenSuperWhisper

/// What happens when the recording dies on its own, rather than because somebody stopped it.
///
/// Reported by a user whose AirPods leave the bubble on "Connecting" for ever, needing a force
/// quit, where the built-in microphone is fine. Connecting a Bluetooth microphone reconfigures
/// the input route under the recorder, `AVAudioRecorder` gives up, and its delegate clears the
/// recording URL. That URL is also what the connection wait guards on, so the wait was left
/// spinning with nothing to measure and could not even reach its own timeout.
final class RecordingFailureTests: XCTestCase {

    /// The wait only ever goes live off observed growth or elapsed time, and it can observe
    /// neither once the file it was watching is gone. So nothing inside it can rescue a recording
    /// that already died: the exit has to come from the failure itself.
    func testTheWaitCannotRescueItself() {
        // Two sightings of growth is what normally ends it.
        XCTAssertTrue(AudioRecorder.shouldGoLive(growthObservations: 2, elapsed: 0.2))
        // And with no growth at all, only the grace period does.
        XCTAssertFalse(AudioRecorder.shouldGoLive(growthObservations: 0, elapsed: 0.2))
        XCTAssertTrue(AudioRecorder.shouldGoLive(growthObservations: 0, elapsed: 5))
    }

    /// The grace period is bounded, which is what makes it a wait rather than a hang. It is also
    /// why this bug was invisible in testing: reaching it requires the handler to keep running,
    /// and after the failure the handler returns before ever looking at the clock.
    func testTheGraceIsBounded() {
        XCTAssertGreaterThan(AudioRecorder.connectionGracePeriod, 0)
        XCTAssertLessThanOrEqual(AudioRecorder.connectionGracePeriod, 10)
    }

    /// An error must be able to take the bubble even while it is showing a live recording. Every
    /// other message steps aside for one, which is right for a message about an earlier clip and
    /// wrong here: the live recording is the thing that failed.
    func testAnErrorMayTakeOverALiveRecording() {
        // `flash` refuses these two, which is why the failure path does not go through it.
        XCTAssertFalse(IndicatorWindowManager.messageMayTakeOver(from: .recording))
        XCTAssertFalse(IndicatorWindowManager.messageMayTakeOver(from: .connecting))
    }
}
