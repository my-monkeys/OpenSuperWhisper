import XCTest
@testable import OpenSuperWhisper

/// `Diag.measure` wraps potentially-blocking calls with logging. It must be a
/// transparent pass-through (same return value, propagates throws) and must
/// leave no in-flight operation behind once it returns — the watchdog relies on
/// `currentInFlight()` being nil when nothing is running.
final class DiagTests: XCTestCase {

    func testMeasureReturnsBodyValue() {
        let result = Diag.measure("test-return") { 21 * 2 }
        XCTAssertEqual(result, 42)
    }

    func testMeasureClearsInFlightAfterReturn() {
        Diag.measure("test-inflight") { _ = 1 }
        XCTAssertNil(Diag.currentInFlight())
    }

    func testMeasureClearsInFlightAfterThrow() {
        struct Boom: Error {}
        XCTAssertThrowsError(try Diag.measure("test-throw") { throw Boom() })
        XCTAssertNil(Diag.currentInFlight())
    }

    func testGapIsTheTimeSinceTheLastBeat() {
        XCTAssertEqual(MainThreadWatchdog.gapNanoseconds(now: 5_000, lastBeat: 2_000), 3_000)
    }

    func testGapIsZeroRightAfterABeat() {
        XCTAssertEqual(MainThreadWatchdog.gapNanoseconds(now: 5_000, lastBeat: 5_000), 0)
    }

    /// The bug: a beat stored after the check read its clock must not wrap into a huge stall.
    func testABeatNewerThanTheClockReadingIsNoGap() {
        XCTAssertEqual(MainThreadWatchdog.gapNanoseconds(now: 5_000, lastBeat: 5_001), 0)
    }
}
