import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Repeated loading and freeing of native contexts in one process.
///
/// whisper.cpp and llama.cpp share one ggml and one Metal device. Freeing a context tears down
/// part of that shared state, and the whisper.cpp fork carries a Metal teardown fix that llama's
/// own ggml copy lacks. The extraction rebuilt all of it as one static library, and this pins
/// what worked before it: contexts come and go, in any order, and the survivors keep transcribing.
final class EngineLifecycleStressTests: XCTestCase {

    private static let unloadKey = "unloadWhisperModelWhenIdle"
    private var savedUnload: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every test here checks the jfk.wav golden after each lifecycle.
        try Fixtures.requireGoldenMachine()
        savedUnload = DefaultsStore.current.object(forKey: Self.unloadKey)
    }

    override func tearDown() {
        if let savedUnload {
            DefaultsStore.current.set(savedUnload, forKey: Self.unloadKey)
        } else {
            DefaultsStore.current.removeObject(forKey: Self.unloadKey)
        }
        super.tearDown()
    }

    /// With "unload when idle" on, every transcription loads the model and frees it afterwards
    /// (#171), so three runs are three full whisper context lifecycles on the same engine. Each
    /// must give the golden, and none may leave the model resident.
    func testIdleUnloadingLoadsAndFreesTheModelOnEveryRun() async throws {
        AppPreferences.shared.unloadWhisperModelWhenIdle = true
        let engine = WhisperEngine(modelPathOverride: Fixtures.tinyEnModel.path)
        try await engine.initialize()
        XCTAssertFalse(engine.isModelLoaded, "initialize() validates the model, then frees it")

        for run in 1...3 {
            let text = try await engine.transcribeAudio(url: Fixtures.jfkWav,
                                                        settings: Fixtures.pinnedSettings())
            XCTAssertEqual(text, WhisperGoldenTests.jfkTranscript, "run \(run)")
            XCTAssertFalse(engine.isModelLoaded, "run \(run) left the model loaded")
        }
    }

    /// whisper and llama contexts created and freed in both orders, which is what the shared
    /// ggml and Metal teardown has to survive. Idle unloading is on, so each transcription loads
    /// and frees a whisper context while a llama context is alive; then llama is used and freed,
    /// and the next round loads both again. Last, with the whisper model kept hot, a llama
    /// context comes and goes beside it (the built-in LLM cleanup between two dictations), and
    /// whisper must still give the golden.
    ///
    /// Needs a GGUF model and never downloads one or looks in the user's Application Support:
    /// `OSW_TEST_GGUF`, passed as `TEST_RUNNER_OSW_TEST_GGUF` through xcodebuild, names it (the
    /// app's smallest cleanup model, qwen2.5-1.5b-instruct-q4_k_m.gguf, is the one this was
    /// written against). Without it the test skips, which keeps the test host away from the
    /// user's data; a run that must cover llama sets it. Each llama load takes a second or so.
    func testWhisperAndLlamaContextsComeAndGoInEitherOrder() async throws {
        let modelPath = try Self.ggufModelFromEnvironment()
        AppPreferences.shared.unloadWhisperModelWhenIdle = true
        let engine = WhisperEngine(modelPathOverride: Fixtures.tinyEnModel.path)
        try await engine.initialize()

        for round in 1...2 {
            var llama = LlamaContext(modelPath: modelPath)
            XCTAssertNotNil(llama, "round \(round): llama.cpp failed to load \(modelPath)")

            let text = try await engine.transcribeAudio(url: Fixtures.jfkWav,
                                                        settings: Fixtures.pinnedSettings())
            XCTAssertEqual(text, WhisperGoldenTests.jfkTranscript, "round \(round)")
            XCTAssertFalse(engine.isModelLoaded, "round \(round): whisper was not freed beside llama")

            let reply = llama?.generate(system: "Answer with one word.", user: "Is water wet?", maxTokens: 4)
            XCTAssertFalse((reply ?? "").isEmpty, "round \(round): the llama context produced nothing")
            llama = nil
        }

        AppPreferences.shared.unloadWhisperModelWhenIdle = false
        let hot = try await WhisperGoldenTests.loadedTinyEngine()
        XCTAssertTrue(hot.isModelLoaded)
        var llama = LlamaContext(modelPath: modelPath)
        XCTAssertFalse((llama?.generate(system: "Answer with one word.", user: "Is fire hot?",
                                        maxTokens: 4) ?? "").isEmpty, "the last llama context produced nothing")
        llama = nil
        XCTAssertTrue(hot.isModelLoaded)
        let text = try await hot.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings())
        XCTAssertEqual(text, WhisperGoldenTests.jfkTranscript, "after the last llama context was freed")
    }

    private static func ggufModelFromEnvironment() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_OSW_TEST_GGUF to a local GGUF model to run the llama half")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("OSW_TEST_GGUF points at a missing file: \(path)")
        }
        return path
    }
}
