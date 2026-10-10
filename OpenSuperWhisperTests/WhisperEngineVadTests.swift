import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The Whisper engine's own VAD, on the engine path.
///
/// `VadIntegrationTests` proves the bundled Silero model loads and finds speech when called
/// directly, and `SpeechTrimmingTests` covers the stitching. Neither shows that the engine uses
/// it: when the model cannot be found, `detectSpeech` returns nothing and the whole clip is
/// transcribed without a word of warning, and `jfk.wav` has so little silence that its
/// transcript is the same either way. The extraction moved the model lookup into an injected
/// path, which is exactly where that silent failure would come back.
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
    ///
    /// The segments are pinned exactly, in centiseconds (deterministic: same input, same model,
    /// same kernels). They pin the engine's padMs 30: 0 or 100 move every boundary. They cannot
    /// pin minSpeechMs, because every segment here is longer than both the engine's 100 ms and
    /// whisper.cpp's default 250 ms; the short burst below does.
    func testEngineVadFindsTheSpeechAndCutsThePadding() async throws {
        try Fixtures.requireGoldenMachine()
        let speech = try await Fixtures.whisperSamples(of: Fixtures.jfkWav)
        let padded = Self.padded(speech)

        let segments = WhisperEngine().detectSpeech(in: padded)
        let trimmed = WhisperEngine.speechOnlySamples(from: padded, segments: segments)

        XCTAssertEqual(segments.map { [$0.startCs, $0.endCs] }, Self.expectedSegments)
        // Both paddings gone, and the pauses inside the speech too.
        XCTAssertEqual(trimmed.count, Self.expectedTrimmedCount)
        XCTAssertLessThan(trimmed.count, speech.count)
    }

    /// [startCs, endCs]: speech starts at 3.30 s, after the 3 s of leading padding, and the last
    /// segment ends at 13.53 s, before the trailing padding; the gaps are JFK's pauses.
    private static let expectedSegments: [[Int64]] = [
        [330, 525], [627, 681], [698, 729], [839, 1062], [1117, 1353],
    ]
    private static let expectedTrimmedCount = 133_760

    /// 150 ms of speech (jfk.wav from 0.50 s) between two seconds of silence. The engine asks
    /// for a 100 ms minimum and keeps it; whisper.cpp's default 250 ms minimum drops it (checked
    /// when this was written), so a move that stopped passing the engine's parameters would
    /// lose short words like this one.
    func testEngineVadKeepsAShortBurstTheLibraryDefaultsDrop() async throws {
        try Fixtures.requireGoldenMachine()
        let speech = try await Fixtures.whisperSamples(of: Fixtures.jfkWav)
        let rate = Fixtures.whisperSampleRate
        let silence = [Float](repeating: 0, count: rate)
        let burst = Array(speech[(rate / 2)..<(rate / 2 + rate * 150 / 1000)])

        let segments = WhisperEngine().detectSpeech(in: silence + burst + silence)

        XCTAssertEqual(segments.map { [$0.startCs, $0.endCs] }, [[96, 121]])
    }

    /// The same padded clip through `transcribeAudio`. Pinned because it differs from the
    /// unpadded golden by one sentence break ("for you. Ask" where the plain clip gives
    /// "for you, ask"): the padding moves the VAD's segment boundaries, and with them the
    /// pauses whisper hears. A change here with the golden unchanged means the trimming moved.
    func testPaddedClipTranscribesFromTheTrimmedAudio() async throws {
        try Fixtures.requireGoldenMachine()
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
