import XCTest

@testable import OpenSuperWhisper

/// Deciding when to stop waiting for a microphone that has to connect first.
///
/// Reported in #98: after locking the Mac and switching from headphones to the built-in
/// microphone, the bubble appeared and the recording never completed or could be stopped, and
/// only force-quitting recovered it. The wait had no way out, so a file that never grew meant
/// waiting forever.
final class ConnectionWaitTests: XCTestCase {

    func testTwoSightingsOfGrowthGoLiveImmediately() {
        XCTAssertTrue(AudioRecorder.shouldGoLive(growthObservations: 2, elapsed: 0.1))
    }

    func testOneSightingIsNotEnoughYet() {
        XCTAssertFalse(AudioRecorder.shouldGoLive(growthObservations: 1, elapsed: 0.1))
    }

    /// The bug. Audio never arriving used to mean waiting for ever, with the bubble up and the
    /// recording unstoppable.
    func testAWaitThatLearnsNothingStillEnds() {
        XCTAssertTrue(AudioRecorder.shouldGoLive(
            growthObservations: 0, elapsed: AudioRecorder.connectionGracePeriod))
        XCTAssertTrue(AudioRecorder.shouldGoLive(growthObservations: 0, elapsed: 30))
    }

    func testItStillWaitsWhileThereIsTimeLeft() {
        let almost = AudioRecorder.connectionGracePeriod - 0.05
        XCTAssertFalse(AudioRecorder.shouldGoLive(growthObservations: 0, elapsed: almost))
    }

    /// Long enough for a Bluetooth headset to wake up, short enough that nobody sits through it
    /// wondering whether the app heard them.
    func testTheGraceIsLongEnoughToBeUsefulAndShortEnoughToBeBearable() {
        XCTAssertGreaterThanOrEqual(AudioRecorder.connectionGracePeriod, 1)
        XCTAssertLessThanOrEqual(AudioRecorder.connectionGracePeriod, 5)
    }
}
