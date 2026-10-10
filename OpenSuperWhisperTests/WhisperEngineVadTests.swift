import XCTest
@testable import OpenSuperWhisper

/// The Whisper engine's own VAD, on the engine path.
///
/// `VadIntegrationTests` proves the bundled Silero model loads and finds speech when called
/// directly, and `SpeechTrimmingTests` covers the stitching. Neither shows that the engine uses
/// it: when the model cannot be found, `detectSpeech` returns nothing and the whole clip is
/// transcribed without a word of warning, and `jfk.wav` has so little silence that its
/// transcript is the same either way. The extraction moves the model lookup into an injected
/// URL, which is exactly where that silent failure would come back.
final class WhisperEngineVadTests: XCTestCase {

    private static let paddingSeconds = 3

    private var tempFiles: [URL] = []

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    /// The engine class must live in the app image, not in a second copy linked into the test
    /// bundle: `Bundle(for:)` would then point at the .xctest, the model would not be found, and
    /// VAD would turn itself off in every test. The path is the one the release smoke check
    /// greps for in whisper.cpp's "loading VAD model" line.
    func testVadModelResolvesFromTheAppBundle() throws {
        XCTAssertEqual(Bundle(for: WhisperEngine.self), Bundle.main)
        let path = try XCTUnwrap(WhisperEngine.vadModelPath)
        XCTAssertTrue(path.hasSuffix("Contents/Resources/ggml-silero-v5.1.2.bin"), path)
    }

    /// jfk.wav with three seconds of digital silence on each side, built in code so the input
    /// is the same on every machine. No model is loaded: `detectSpeech` only needs the VAD.
    func testEngineVadFindsTheSpeechAndCutsThePadding() async throws {
        let speech = try await Fixtures.whisperSamples(of: Fixtures.jfkWav)
        let padded = Self.padded(speech)

        let segments = WhisperEngine().detectSpeech(in: padded)

        XCTAssertFalse(segments.isEmpty, "the engine's VAD did not run, or heard nothing")
        let firstStart = Double(try XCTUnwrap(segments.first).startCs) / 100
        XCTAssertEqual(firstStart, Double(Self.paddingSeconds), accuracy: 0.5,
                       "speech located somewhere other than after the leading padding")

        let trimmed = WhisperEngine.speechOnlySamples(from: padded, segments: segments)
        let rate = Fixtures.whisperSampleRate
        // Both paddings gone, and then some: the VAD also drops the pauses inside the speech.
        XCTAssertLessThan(trimmed.count, speech.count)
        XCTAssertLessThan(trimmed.count, padded.count - 2 * Self.paddingSeconds * rate)
    }

    /// The same padded clip through `transcribeAudio`. Pinned because it differs from the
    /// unpadded golden by one sentence break ("for you. Ask" where the plain clip gives
    /// "for you, ask"): the padding moves the VAD's segment boundaries, and with them the
    /// pauses whisper hears. A change here with the golden unchanged means the trimming moved.
    func testPaddedClipTranscribesFromTheTrimmedAudio() async throws {
        let speech = try await Fixtures.whisperSamples(of: Fixtures.jfkWav)
        let url = try Fixtures.writeWhisperWav(Self.padded(speech), name: "jfk-padded")
        tempFiles.append(url)

        let engine = try await WhisperGoldenTests.loadedTinyEngine()
        let text = try await engine.transcribeAudio(url: url,
                                                    settings: Fixtures.pinnedSettings())

        XCTAssertEqual(text, "And so my fellow Americans ask not what your country can do for you. "
                       + "Ask what you can do for your country.")
    }

    private static func padded(_ speech: [Float]) -> [Float] {
        let silence = [Float](repeating: 0, count: paddingSeconds * Fixtures.whisperSampleRate)
        return silence + speech + silence
    }
}
