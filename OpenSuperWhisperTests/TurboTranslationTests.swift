import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Whisper translates, but its turbo builds do not, and they say nothing about it.
///
/// Measured on one Czech clip through the app's own engine: `ggml-small` returned English with
/// `translate` set, `ggml-large-v3-turbo-q5_0` returned the Czech unchanged and byte-identical
/// to the untranslated run. Since every Whisper model the setup screen offers is a turbo build,
/// a user who followed setup had no configuration that could translate, and nothing said so.
final class TurboTranslationTests: XCTestCase {

    func testTurboModelsCannotTranslate() {
        for name in ["ggml-large-v3-turbo.bin",
                     "ggml-large-v3-turbo-q8_0.bin",
                     "ggml-large-v3-turbo-q5_0.bin"] {
            XCTAssertFalse(
                EngineCapabilities.supportsTranslation(engine: "whisper",
                                                       modelPath: "/models/\(name)"),
                "\(name) is a turbo build; offering translation would do nothing")
        }
    }

    func testNonTurboWhisperModelsCan() {
        for name in ["ggml-small.bin", "ggml-medium.bin", "ggml-large-v3.bin"] {
            XCTAssertTrue(
                EngineCapabilities.supportsTranslation(engine: "whisper",
                                                       modelPath: "/models/\(name)"))
        }
    }

    /// Matching on the file name is crude, so it must not be fooled by the directory.
    func testTurboInTheFolderNameDoesNotCount() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(
            engine: "whisper", modelPath: "/Users/me/turbo-models/ggml-small.bin"))
    }

    func testUnknownModelIsAssumedCapable() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "whisper", modelPath: nil))
    }

    /// The engine-level rule still wins: Parakeet and SenseVoice never translate, turbo or not.
    func testEnginesThatNeverTranslateStayBlocked() {
        for engine in ["fluidaudio", "sensevoice"] {
            XCTAssertFalse(EngineCapabilities.supportsTranslation(
                engine: engine, modelPath: "/models/ggml-small.bin"))
        }
    }

    func testRemoteServersAreLeftAlone() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "remote", modelPath: nil))
    }
}
