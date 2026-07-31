import XCTest

@testable import OpenSuperWhisper

/// The indicator's meter turns `averagePower` decibels into bar fills. Both steps are pure,
/// so they're pinned here rather than judged by eye on a running bubble (#47).
final class AudioLevelTests: XCTestCase {

    func testSilenceAndFullScaleMapToTheEnds() {
        XCTAssertEqual(AudioLevel.normalize(power: -160), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.normalize(power: AudioLevel.floorDb), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.normalize(power: 0), 1, accuracy: 0.001)
    }

    /// -160 dB is the documented floor, but a dead channel can report -infinity.
    func testNonFinitePowerReadsAsSilence() {
        XCTAssertEqual(AudioLevel.normalize(power: -.infinity), 0)
        XCTAssertEqual(AudioLevel.normalize(power: .nan), 0)
    }

    func testLouderInputNeverReadsLower() {
        let samples: [Float] = [-80, -55, -40, -30, -20, -10, -3, 0]
        for (quiet, loud) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(AudioLevel.normalize(power: quiet),
                                     AudioLevel.normalize(power: loud),
                                     "\(loud) dB should not read below \(quiet) dB")
        }
    }

    /// A normal speaking voice sits near -30 dB. A linear dB rescale would leave it under
    /// half a bar of five; the curve has to put it somewhere legible.
    func testSpeakingVoiceLandsInTheMiddleOfTheMeter() {
        let level = AudioLevel.normalize(power: -30)
        XCTAssertGreaterThan(level, 0.4)
        XCTAssertLessThan(level, 0.9)
    }

    func testBarsFillFromTheBottomUp() {
        XCTAssertEqual(AudioLevel.barFill(index: 0, count: 5, level: 1), 1)
        XCTAssertEqual(AudioLevel.barFill(index: 4, count: 5, level: 1), 1)
        XCTAssertEqual(AudioLevel.barFill(index: 4, count: 5, level: 0.5), 0)
        XCTAssertEqual(AudioLevel.barFill(index: 0, count: 5, level: 0.5), 1)
        // Level 0.5 lands inside the third bar (0.4...0.6), half filled.
        XCTAssertEqual(AudioLevel.barFill(index: 2, count: 5, level: 0.5), 0.5, accuracy: 0.001)
    }

    func testSilenceLeavesEveryBarEmpty() {
        for index in 0..<5 {
            XCTAssertEqual(AudioLevel.barFill(index: index, count: 5, level: 0), 0)
        }
    }
}
