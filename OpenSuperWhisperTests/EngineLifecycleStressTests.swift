import XCTest
@testable import OpenSuperWhisper

/// Repeated loading and freeing of native contexts in one process.
///
/// whisper.cpp and llama.cpp share one ggml and one Metal device. Freeing a context tears down
/// part of that shared state, and the whisper.cpp fork carries a Metal teardown fix that llama's
/// own ggml copy lacks. The extraction rebuilds all of it as one static library, so this pins
/// what works today: contexts come and go, in any order, and the survivors keep transcribing.
final class EngineLifecycleStressTests: XCTestCase {

    private static let unloadKey = "unloadWhisperModelWhenIdle"
    private var savedUnload: Any?

    override func setUp() {
        super.setUp()
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

    /// A llama context created, used on the GPU and freed while a whisper context stays alive,
    /// then whisper transcribes again. This is the built-in LLM cleanup running between two
    /// dictations with the Whisper model kept hot.
    ///
    /// Needs a GGUF model on disk and never downloads one: `OSW_TEST_GGUF` (passed as
    /// `TEST_RUNNER_OSW_TEST_GGUF` through xcodebuild) names one, otherwise the app's smallest
    /// cleanup model is used if this Mac already has it. It is only read, memory-mapped by
    /// llama.cpp, so the test host's isolation from user data still holds for writes. Takes a
    /// second or two for the 1.1 GB model.
    func testLlamaContextComesAndGoesBesideALiveWhisperContext() async throws {
        let modelPath = try Self.localGGUFModel()
        AppPreferences.shared.unloadWhisperModelWhenIdle = false
        let engine = try await WhisperGoldenTests.loadedTinyEngine()
        XCTAssertTrue(engine.isModelLoaded)

        var llama = LlamaContext(modelPath: modelPath)
        XCTAssertNotNil(llama, "llama.cpp failed to load \(modelPath)")
        let reply = llama?.generate(system: "Answer with one word.", user: "Is water wet?", maxTokens: 4)
        XCTAssertFalse((reply ?? "").isEmpty, "the llama context produced nothing")
        llama = nil

        XCTAssertTrue(engine.isModelLoaded)
        let text = try await engine.transcribeAudio(url: Fixtures.jfkWav,
                                                    settings: Fixtures.pinnedSettings())
        XCTAssertEqual(text, WhisperGoldenTests.jfkTranscript)
    }

    private static func localGGUFModel() throws -> String {
        if let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("OSW_TEST_GGUF points at a missing file: \(path)")
            }
            return path
        }
        // The production directory on purpose: the test storage root is empty by design.
        guard let root = AppIdentity.applicationSupportDirectory() else {
            throw XCTSkip("No Application Support directory")
        }
        let path = LLMModelManager.modelsDirectory(in: root)
            .appendingPathComponent(LLMModelManager.defaultModel.fileName).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No local GGUF model (set OSW_TEST_GGUF, or download "
                          + "\(LLMModelManager.defaultModel.fileName) in the app); not downloading one")
        }
        return path
    }
}
