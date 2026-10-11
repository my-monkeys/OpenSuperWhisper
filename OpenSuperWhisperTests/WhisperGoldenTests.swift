import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Byte-exact transcripts of `jfk.wav` through the real Whisper engine path (conversion, VAD,
/// whisper.cpp, cleanup, post-processing) with the tiny English model tracked in the repo.
///
/// These are the reference the core extraction was measured against: moving the engine, the
/// wrappers and the native build left every string here unchanged, and later changes must too.
/// A failure is a behaviour change to explain, never a golden to re-record without review.
///
/// The strings can depend on the ggml kernels and the GPU, so they are only promised on the
/// machine and toolchain they were recorded with (Apple Silicon M-series, Metal, Xcode 27.0);
/// `Fixtures.requireGoldenMachine()` skips them elsewhere. They came out byte-identical under
/// three libwhisper configurations: run.sh's (GGML_NATIVE=ON, so -mcpu=native+dotprod+i8mm, at
/// -O0), notarize_app.sh's configure (GGML_NATIVE=OFF, arm64 and x86_64, generic CPU kernels)
/// at -O0, and that same configure with the Debug flags set to -O3 -DNDEBUG, which is the
/// generic-kernel optimised build Debug and the tests moved to in slice 2. The exact VAD pins in
/// `WhisperEngineVadTests` came later and were checked under the first and the last. A config
/// switch that changes them is a real difference, not an expected one.
final class WhisperGoldenTests: XCTestCase {

    static let jfkTranscript =
        "And so my fellow Americans ask not what your country can do for you, "
        + "ask what you can do for your country."

    /// Each segment on its own line behind its "[t0->t1] " prefix. The double space is real:
    /// whisper.cpp's segment text starts with a space and nothing trims it before the prefix
    /// is joined on.
    static let jfkTranscriptWithTimestamps =
        "[0.0->8.0]  And so my fellow Americans ask not what your country can do for you\n"
        + "[8.0->11.0]  ask what you can do for your country."

    static func loadedTinyEngine() async throws -> WhisperEngine {
        let engine = WhisperEngine(modelPathOverride: Fixtures.tinyEnModel.path)
        try await engine.initialize()
        return engine
    }

    private var tempFiles: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try Fixtures.requireGoldenMachine()
    }

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    func testJFKTinyEnTranscriptIsExact() async throws {
        let engine = try await Self.loadedTinyEngine()
        let text = try await engine.transcribeAudio(url: Fixtures.jfkWav,
                                                    settings: Fixtures.pinnedSettings())
        XCTAssertEqual(text, Self.jfkTranscript)
    }

    /// Timestamps skip the VAD (trimming would shift them off the file) and change the output
    /// format, which the history view and the CLI print as is.
    func testJFKWithTimestampsKeepsTheSegmentFormat() async throws {
        let engine = try await Self.loadedTinyEngine()
        let text = try await engine.transcribeAudio(url: Fixtures.jfkWav,
                                                    settings: Fixtures.pinnedSettings(showTimestamps: true))
        XCTAssertEqual(text, Self.jfkTranscriptWithTimestamps)
    }

    /// Five seconds of digital silence come back as the no-speech marker, which the pipeline
    /// matches to skip pasting. The VAD finds nothing, so the whole clip reaches whisper, and
    /// its blank output is turned into the marker by post-processing.
    func testSilenceReportsNoSpeech() async throws {
        let engine = try await Self.loadedTinyEngine()
        let url = try silence(seconds: 5)
        let text = try await engine.transcribeAudio(url: url, settings: Fixtures.pinnedSettings())
        XCTAssertEqual(text, TranscriptionResult.noSpeech)
    }

    /// Pinned as it is, though it looks wrong: with timestamps on, silence does not report no
    /// speech. The timestamp prefix is added before "[BLANK_AUDIO]" is stripped, so a segment
    /// with no words still leaves its prefix, and its end time (10.0 s) is past the 5 s clip.
    func testSilenceWithTimestampsLeavesABarePrefix() async throws {
        let engine = try await Self.loadedTinyEngine()
        let url = try silence(seconds: 5)
        let text = try await engine.transcribeAudio(url: url,
                                                    settings: Fixtures.pinnedSettings(showTimestamps: true))
        XCTAssertEqual(text, "[0.0->10.0]")
    }

    private func silence(seconds: Int) throws -> URL {
        let samples = [Float](repeating: 0, count: seconds * Fixtures.whisperSampleRate)
        let url = try Fixtures.writeWhisperWav(samples, name: "silence")
        tempFiles.append(url)
        return url
    }
}
