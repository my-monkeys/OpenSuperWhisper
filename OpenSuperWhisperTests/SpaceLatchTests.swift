import XCTest

@testable import OpenSuperWhisper

/// Covers the two pieces of the Space latch that can be exercised without an event tap: the
/// double-tap timing rule, and the indicator's latched flag clearing itself so a latch can't leak
/// into the next recording.
final class SpaceLatchTests: XCTestCase {

    // MARK: - Double-tap detection

    func testTwoTapsInsideTheWindowAreADoubleTap() {
        XCTAssertTrue(ShortcutManager.isDoubleTap(now: 10.30, previous: 10.0, threshold: 0.35))
    }

    func testTapsOutsideTheWindowAreNot() {
        // Two separate recordings, not a latch gesture.
        XCTAssertFalse(ShortcutManager.isDoubleTap(now: 10.40, previous: 10.0, threshold: 0.35))
    }

    func testFirstEverTapIsNotADoubleTap() {
        // `lastKeyDownTime` starts at 0 while `systemUptime` is however long the machine has been
        // up, so the very first press must not read as the second half of a double-tap.
        XCTAssertFalse(ShortcutManager.isDoubleTap(now: 48_000, previous: 0, threshold: 0.35))
    }

    // MARK: - Latch chime suppression

    func testDoubleTapLatchDoesNotStackASecondChime() {
        // The second tap lands inside the double-tap window, so its chime would arrive on top of
        // the recording-start one.
        XCTAssertFalse(ShortcutManager.shouldPlayLatchSound(sinceRecordingStart: 0.2))
        XCTAssertFalse(ShortcutManager.shouldPlayLatchSound(sinceRecordingStart: 0.35))
    }

    func testLatchingLaterStillPlaysTheChime() {
        // Hold, talk for a while, then reach for Space: the recording has been running long
        // enough that a confirmation is useful rather than noisy.
        XCTAssertTrue(ShortcutManager.shouldPlayLatchSound(sinceRecordingStart: 2))
        XCTAssertTrue(ShortcutManager.shouldPlayLatchSound(sinceRecordingStart: 30))
    }

    func testQuietWindowClearsTheDoubleTapWindow() {
        XCTAssertGreaterThan(ShortcutManager.latchSoundQuietWindow, 0.35,
                             "must outlast the double-tap window it exists to cover")
    }

    // MARK: - Latched flag lifecycle

    @MainActor
    func testStartDecodingClearsTheLatch() {
        let vm = IndicatorViewModel()
        vm.isLatched = true

        vm.startDecoding()

        XCTAssertFalse(vm.isLatched, "a latch must not survive into transcription")
    }

    @MainActor
    func testCleanupClearsTheLatch() {
        let vm = IndicatorViewModel()
        vm.isLatched = true

        vm.cleanup()

        XCTAssertFalse(vm.isLatched, "a discarded recording must not leave the bubble latched")
    }

    @MainActor
    func testFreshViewModelIsNotLatched() {
        XCTAssertFalse(IndicatorViewModel().isLatched)
    }
}
