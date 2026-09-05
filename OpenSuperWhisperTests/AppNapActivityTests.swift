import XCTest

@testable import OpenSuperWhisper

/// Holding App Nap off for the duration of a recording.
///
/// Reported in #98 as a freeze after switching audio input: the recording bubble stayed up, no
/// state ever changed, the trigger key did nothing, and force-quitting was the only way out.
/// Nothing was actually stuck. App Nap had suspended the app's timers and deferred its main-queue
/// work, because it only suppresses App Nap for audio *output* — a recorder has to say so itself.
/// CoreAudio's I/O threads are real-time and unaffected, so the clip kept growing the whole time,
/// which is what made it look like a hang rather than a throttle.
///
/// What is worth testing here is not App Nap itself — that is the system's behaviour, and the fix
/// was verified against the real bug — but that the assertion is always balanced. A leaked
/// assertion holds App Nap off for the rest of the process's life, which is invisible until
/// something else needs the power.
final class AppNapActivityTests: XCTestCase {

    private var recorder: AudioRecorder { AudioRecorder.shared }

    override func tearDown() {
        recorder.endRecordingActivity()
        super.tearDown()
    }

    func testNoActivityIsHeldWhileIdle() {
        recorder.endRecordingActivity()
        XCTAssertFalse(recorder.isHoldingRecordingActivity)
    }

    func testBeginningHoldsAnActivity() {
        recorder.beginRecordingActivity()
        XCTAssertTrue(recorder.isHoldingRecordingActivity)
    }

    func testEndingReleasesIt() {
        recorder.beginRecordingActivity()
        recorder.endRecordingActivity()
        XCTAssertFalse(recorder.isHoldingRecordingActivity)
    }

    /// The leak that matters. Two starts without a stop between them must not stack, or the second
    /// assertion outlives every `endRecordingActivity` and App Nap stays off for good.
    func testTwoStartsDoNotStackAssertions() {
        recorder.beginRecordingActivity()
        recorder.beginRecordingActivity()
        recorder.endRecordingActivity()
        XCTAssertFalse(recorder.isHoldingRecordingActivity)
    }

    /// Ending is used both on every exit path and as the guard inside `beginRecordingActivity`,
    /// so it has to tolerate being called with nothing held.
    func testEndingWithNothingHeldIsHarmless() {
        recorder.endRecordingActivity()
        recorder.endRecordingActivity()
        XCTAssertFalse(recorder.isHoldingRecordingActivity)
    }

    /// Cancelling a recording releases the assertion, the same as stopping one. Esc used to be the
    /// only way out of the state in #98, so it must not be the path that leaks.
    func testCancellingARecordingReleasesTheActivity() {
        recorder.beginRecordingActivity()
        recorder.cancelRecording()
        XCTAssertFalse(recorder.isHoldingRecordingActivity)
    }
}
