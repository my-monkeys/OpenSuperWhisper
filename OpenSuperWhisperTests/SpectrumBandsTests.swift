import XCTest

@testable import OpenSuperWhisper

/// The visualiser's frequency layout and scaling. Pure maths, so it's pinned here rather
/// than judged by watching bars move (#47).
final class SpectrumBandsTests: XCTestCase {

    func testEdgesSpanTheSpeechRangeAndAscend() {
        let edges = SpectrumBands.edges()
        XCTAssertEqual(edges.count, SpectrumBands.count + 1)
        XCTAssertEqual(edges.first!, SpectrumBands.lowestHz, accuracy: 0.01)
        XCTAssertEqual(edges.last!, SpectrumBands.highestHz, accuracy: 0.1)
        for (low, high) in zip(edges, edges.dropFirst()) {
            XCTAssertLessThan(low, high)
        }
    }

    /// Logarithmic spacing is the point: every band should cover the same musical interval,
    /// so vowels don't all land in band one.
    func testEdgesAreLogarithmicallySpaced() {
        let edges = SpectrumBands.edges()
        let ratios = zip(edges, edges.dropFirst()).map { $1 / $0 }
        for ratio in ratios {
            XCTAssertEqual(ratio, ratios[0], accuracy: 0.001)
        }
    }

    func testBinRangesAreOrderedNonEmptyAndInsideTheSpectrum() {
        let fftSize = 1024
        let ranges = SpectrumBands.binRanges(sampleRate: 48000, fftSize: fftSize)
        XCTAssertEqual(ranges.count, SpectrumBands.count)
        for range in ranges {
            XCTAssertFalse(range.isEmpty, "every band needs at least one bin to average")
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, fftSize / 2)
        }
        for (lower, upper) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(lower.lowerBound, upper.lowerBound)
        }
    }

    /// A high sample rate makes the lowest band narrower than one bin; it still has to
    /// resolve to something drawable.
    func testLowBandSurvivesAHighSampleRate() {
        let ranges = SpectrumBands.binRanges(sampleRate: 96000, fftSize: 512)
        XCTAssertEqual(ranges.count, SpectrumBands.count)
        XCTAssertFalse(ranges[0].isEmpty)
    }

    func testNormalizeClampsAndOrders() {
        XCTAssertEqual(SpectrumBands.normalize(magnitude: 0), 0)
        XCTAssertEqual(SpectrumBands.normalize(magnitude: -1), 0)
        XCTAssertEqual(SpectrumBands.normalize(magnitude: 1), 1, accuracy: 0.001)
        XCTAssertGreaterThan(SpectrumBands.normalize(magnitude: 0.1),
                             SpectrumBands.normalize(magnitude: 0.001))
    }

    func testNonFiniteMagnitudeReadsAsSilence() {
        XCTAssertEqual(SpectrumBands.normalize(magnitude: .infinity), 0)
        XCTAssertEqual(SpectrumBands.normalize(magnitude: .nan), 0)
    }

    /// Bars rise quickly and fall slowly, so speech reads as a voice instead of flickering.
    func testSmoothingRisesFasterThanItFalls() {
        let rising = SpectrumBands.smooth(previous: 0, next: 1)
        let falling = SpectrumBands.smooth(previous: 1, next: 0)
        XCTAssertGreaterThan(rising, 1 - falling,
                             "a jump up should move further than the same jump down")
        XCTAssertGreaterThan(falling, 0, "bars must not snap straight to silence")
    }

    func testSmoothingConvergesAndStaysInRange() {
        var value: Float = 0
        for _ in 0..<40 { value = SpectrumBands.smooth(previous: value, next: 1) }
        XCTAssertEqual(value, 1, accuracy: 0.01)
        for _ in 0..<80 { value = SpectrumBands.smooth(previous: value, next: 0) }
        XCTAssertEqual(value, 0, accuracy: 0.01)
    }
}
