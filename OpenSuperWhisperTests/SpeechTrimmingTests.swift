import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The VAD gate is allowed to make whisper faster, never to lose words. These pin the rule
/// that trimming only ever *removes silence*, and that every degenerate case the VAD can hand
/// back falls through to "transcribe everything" instead of returning an empty buffer.
final class SpeechTrimmingTests: XCTestCase {

    private let sampleRate = 16000

    /// A ramp makes each sample identifiable, so we can assert *which* audio survived.
    private func ramp(seconds: Int) -> [Float] {
        (0..<(seconds * sampleRate)).map { Float($0) }
    }

    func testKeepsTheSpeechRegionWithRoomBeforeItAndLittleAfter() {
        let samples = ramp(seconds: 10)
        let trimmed = WhisperEngine.speechOnlySamples(
            from: samples, segments: [WhisperVadSegment(startCs: 200, endCs: 400)])

        let onset = WhisperEngine.onsetPaddingMs * sampleRate / 1000
        let tail = WhisperEngine.tailPaddingMs * sampleRate / 1000
        XCTAssertEqual(trimmed.count, 2 * sampleRate + onset + tail)
        XCTAssertEqual(trimmed.first, Float(2 * sampleRate - onset),
                       "the kept audio starts before the speech, to protect the first consonant")
    }

    /// The two ends want opposite things: room before the first word so its opening consonant
    /// survives, and as little as possible after the last, because trailing silence is what makes
    /// Whisper invent a closing phrase (#87).
    func testTheTailIsMuchShorterThanTheOnset() {
        XCTAssertLessThan(WhisperEngine.tailPaddingMs, WhisperEngine.onsetPaddingMs / 4)
    }

    /// The regression this came from: 100ms of VAD padding on both sides plus 100ms of overlap
    /// on every segment end left 200ms of non-speech at the end of the clip.
    func testTheTailIsShorterThanItWasWhenHallucinationWasReported() {
        XCTAssertLessThan(WhisperEngine.tailPaddingMs, 100)
    }

    /// Two segments are separated by a short silence so the decoder still hears a pause,
    /// rather than two phrases welded into one sentence.
    func testInsertsSilenceBetweenSegments() {
        let samples = ramp(seconds: 10)
        let trimmed = WhisperEngine.speechOnlySamples(
            from: samples,
            segments: [WhisperVadSegment(startCs: 100, endCs: 200),
                       WhisperVadSegment(startCs: 500, endCs: 600)])

        let oneSecond = sampleRate
        let onset = WhisperEngine.onsetPaddingMs * sampleRate / 1000
        let interior = WhisperEngine.interiorOverlapMs * sampleRate / 1000
        let tail = WhisperEngine.tailPaddingMs * sampleRate / 1000

        // first: onset + 1s + interior, then the gap, then: 1s + tail
        XCTAssertEqual(trimmed.count, (onset + oneSecond + interior) + interior + (oneSecond + tail))

        let gapStart = onset + oneSecond + interior
        XCTAssertEqual(Array(trimmed[gapStart..<(gapStart + interior)]),
                       [Float](repeating: 0, count: interior))
    }

    /// No speech found is *not* a verdict of silence: the caller re-sends the whole clip, so
    /// a sentence the VAD failed to hear is still transcribed.
    func testNoSegmentsYieldsEmptySoCallerCanFallBack() {
        XCTAssertTrue(WhisperEngine.speechOnlySamples(from: ramp(seconds: 3), segments: []).isEmpty)
    }

    /// Backwards or zero-length segments are skipped rather than trusted into a crash.
    func testDegenerateSegmentsAreSkipped() {
        let samples = ramp(seconds: 5)
        let trimmed = WhisperEngine.speechOnlySamples(
            from: samples,
            segments: [WhisperVadSegment(startCs: 300, endCs: 100),
                       WhisperVadSegment(startCs: 200, endCs: 200)])

        XCTAssertTrue(trimmed.isEmpty)
    }

    /// A segment running past the end of the clip is clamped, not read out of bounds.
    func testSegmentBeyondTheEndIsClamped() {
        let samples = ramp(seconds: 2)
        let trimmed = WhisperEngine.speechOnlySamples(
            from: samples, segments: [WhisperVadSegment(startCs: 100, endCs: 9999)])

        let onset = WhisperEngine.onsetPaddingMs * sampleRate / 1000
        XCTAssertEqual(trimmed.count, sampleRate + onset, "clamped to what the clip actually holds")
        XCTAssertEqual(trimmed.last, Float(2 * sampleRate - 1))
    }

    /// Trimming must never invent audio: the result is always shorter than the input.
    func testTrimmingNeverGrowsTheBuffer() {
        let samples = ramp(seconds: 6)
        let segments = (0..<5).map {
            WhisperVadSegment(startCs: Int64($0 * 100), endCs: Int64($0 * 100 + 50))
        }
        let trimmed = WhisperEngine.speechOnlySamples(from: samples, segments: segments)

        XCTAssertLessThan(trimmed.count, samples.count)
    }

    /// The model has to actually be in the bundle, or the gate silently never runs. This is
    /// the check that a bundling slip would otherwise hide until someone timed a dictation.
    func testVadModelIsBundled() {
        XCTAssertNotNil(WhisperEngine.vadModelPath,
                        "ggml-silero-v5.1.2.bin must ship inside the app bundle")
    }
}
