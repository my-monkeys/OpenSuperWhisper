import XCTest
@testable import OpenSuperWhisperCore

/// The measurement blob and the clock that feeds it (#262). Pure: nothing is timed for real,
/// and a corrupt blob must never throw.
final class DictationTimingTests: CoreTestCase {

    private static func full() -> DictationTiming {
        var timing = DictationTiming()
        timing.finalizeMs = 120
        timing.queueWaitMs = 15
        timing.engineWaitMs = 0
        timing.engineLoadMs = 2_100
        timing.transcribeMs = 1_200
        timing.transcribeAttempts = 1
        timing.cleanupMs = 600
        timing.insertMs = 40
        timing.totalMs = 4_075
        timing.machine = MachineState(thermalState: "nominal", lowPowerMode: false, loadAverage1m: 1.25)
        return timing
    }

    // MARK: - Round trip

    func testEveryStageSurvivesTheRoundTrip() {
        let timing = Self.full()

        let decoded = DictationTiming.decode(timing.encoded)

        XCTAssertEqual(decoded, timing)
    }

    /// A partial measurement is the common case: a streamed-only dictation has no engine run
    /// and a failure has no insertion. Those nils must come back as nils, not as zeroes.
    func testPartialValueRoundTrips() {
        var timing = DictationTiming()
        timing.finalizeMs = 90
        timing.queueWaitMs = 4
        timing.totalMs = 300

        let decoded = DictationTiming.decode(timing.encoded)

        XCTAssertEqual(decoded, timing)
        XCTAssertNil(decoded?.transcribeMs)
        XCTAssertNil(decoded?.cleanupMs)
        XCTAssertNil(decoded?.machine)
    }

    func testNilIsNotZero() {
        var timing = DictationTiming()
        timing.engineLoadMs = 0
        timing.cleanupMs = nil

        let decoded = DictationTiming.decode(timing.encoded)

        XCTAssertEqual(decoded?.engineLoadMs, 0, "it ran and cost nothing measurable")
        XCTAssertNil(decoded?.cleanupMs, "no pass was due")
    }

    // MARK: - Failure is nil, never a partial read

    func testEmptyValueEncodesToNil() {
        let timing = DictationTiming()

        XCTAssertTrue(timing.isEmpty)
        XCTAssertNil(timing.encoded, "an empty value must leave the column NULL, not hold {version:1}")
    }

    func testNilInputDecodesToNil() {
        XCTAssertNil(DictationTiming.decode(nil))
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(DictationTiming.decode("{not json"))
        XCTAssertNil(DictationTiming.decode(""))
        XCTAssertNil(DictationTiming.decode("null"))
    }

    /// A newer build's blob must not decode into this struct with its unknown stages dropped:
    /// that would present a partial measurement as a whole one.
    func testNewerVersionDecodesToNil() {
        let json = #"{"version":\#(DictationTiming.currentVersion + 1),"totalMs":1000}"#

        XCTAssertNil(DictationTiming.decode(json))
    }

    func testCurrentVersionDecodes() {
        let json = #"{"version":1,"totalMs":1000}"#

        XCTAssertEqual(DictationTiming.decode(json)?.totalMs, 1_000)
    }

    // MARK: - Clock

    func testMillisecondsMeasuresTheDelta() {
        XCTAssertEqual(UptimeClock.milliseconds(from: 0, to: 2_000_000), 2)
        XCTAssertEqual(UptimeClock.milliseconds(from: 1_000_000, to: 1_500_000), 0, "sub-millisecond")
        XCTAssertEqual(UptimeClock.milliseconds(from: 5, to: 5), 0)
    }

    /// A reversed pair must not trap and must not produce a negative duration.
    func testMillisecondsIsWrapperSafe() {
        XCTAssertGreaterThanOrEqual(UptimeClock.milliseconds(from: 10, to: 0), 0)
    }

    // MARK: - Machine state

    func testMachineStateRoundTrips() {
        let machine = MachineState(thermalState: "serious", lowPowerMode: true, loadAverage1m: nil)
        var timing = DictationTiming()
        timing.finalizeMs = 1
        timing.machine = machine

        let decoded = DictationTiming.decode(timing.encoded)

        XCTAssertEqual(decoded?.machine, machine)
        XCTAssertNil(decoded?.machine?.loadAverage1m, "getloadavg failing is not a zero")
    }
}
