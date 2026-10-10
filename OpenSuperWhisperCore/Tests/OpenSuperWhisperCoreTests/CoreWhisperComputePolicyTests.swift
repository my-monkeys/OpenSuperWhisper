import XCTest
@testable import OpenSuperWhisperCore

/// Whisper built through the designated initialiser, the way the iPhone app will build it, under
/// both compute policies. `.cpuOnly` creates the context with `use_gpu = false`; the VAD always
/// runs on the CPU, so it needs no gate of its own.
///
/// The exact strings are the hosted goldens (`WhisperGoldenTests`), copied: the standalone package
/// must give the app's transcript. Where the CPU differs from Metal, the measured string has its
/// own constant; a difference is never a reason to loosen a check to "contains".
final class CoreWhisperComputePolicyTests: CoreTestCase {

    static let jfkTranscript =
        "And so my fellow Americans ask not what your country can do for you, "
        + "ask what you can do for your country."

    /// Measured in slice 5 (M5 Pro, Xcode 27.0): with `use_gpu = false` the VAD-trimmed clip ends
    /// its first sentence with a full stop instead of Metal's comma. Identical on macOS (generic
    /// CPU kernels) and on the iOS 26.5 simulator (baseline arm64 kernels), and stable across
    /// runs. The timestamped run, which skips the VAD, matches Metal byte for byte.
    static let jfkTranscriptCPU =
        "And so my fellow Americans ask not what your country can do for you. "
        + "Ask what you can do for your country."

    static let jfkTranscriptWithTimestamps =
        "[0.0->8.0]  And so my fellow Americans ask not what your country can do for you\n"
        + "[8.0->11.0]  ask what you can do for your country."

    private var tempFiles: [URL] = []

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    /// No gate: the one whisper inference CI runs, on macOS and on the simulator, on the CPU.
    func testCPUOnlyTranscribesJFK() async throws {
        let text = try await transcribe(Fixtures.jfkWav, policy: .cpuOnly)
        XCTAssertTrue(text.lowercased().contains("ask not what your country can do for you"), text)
    }

    func testCPUOnlyTranscriptIsExact() async throws {
        try Fixtures.requireCPUGoldenMachine()
        let text = try await transcribe(Fixtures.jfkWav, policy: .cpuOnly)
        XCTAssertEqual(text, Self.jfkTranscriptCPU)
    }

    func testCPUOnlyTimestampsAreExact() async throws {
        try Fixtures.requireCPUGoldenMachine()
        let text = try await transcribe(Fixtures.jfkWav, policy: .cpuOnly, showTimestamps: true)
        XCTAssertEqual(text, Self.jfkTranscriptWithTimestamps)
    }

    func testCPUOnlySilenceReportsNoSpeech() async throws {
        try Fixtures.requireCPUGoldenMachine()
        let text = try await transcribe(try silence(seconds: 5), policy: .cpuOnly)
        XCTAssertEqual(text, TranscriptionResult.noSpeech)
    }

    func testAutomaticTranscriptIsExact() async throws {
        try Fixtures.requireGoldenMachine()
        let text = try await transcribe(Fixtures.jfkWav, policy: .automatic)
        XCTAssertEqual(text, Self.jfkTranscript)
    }

    // MARK: - Helpers

    private func transcribe(_ url: URL, policy: ComputePolicy, showTimestamps: Bool = false) async throws -> String {
        let engine = WhisperEngine(modelPathOverride: Fixtures.tinyEnModel.path,
                                   vadModelPath: Fixtures.sileroVAD.path,
                                   computePolicy: policy)
        try await engine.initialize()
        return try await engine.transcribeAudio(url: url,
                                                settings: Fixtures.pinnedSettings(showTimestamps: showTimestamps))
    }

    private func silence(seconds: Int) throws -> URL {
        let samples = [Float](repeating: 0, count: seconds * Fixtures.whisperSampleRate)
        let url = try Fixtures.writeWhisperWav(samples, name: "silence")
        tempFiles.append(url)
        return url
    }
}
