import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The regenerate menu offers only models that can transcribe the recording now (#275): a chat
/// model from a Remote server, a Remote server nobody configured, or an engine that is not
/// installed would each be a row that can only fail.
final class RegenerationModelsTests: XCTestCase {

    private func option(_ engine: String, _ id: String) -> DictationModelOption {
        DictationModelOption(engine: engine, identifier: id, displayName: id)
    }

    func testRemoteKeepsTranscriptionModelsAndDropsChatModels() {
        let models = RegenerationModels.usable(.init(
            remote: [option("remote", "whisper-large-v3-turbo"), option("remote", "gpt-oss-120b"),
                     option("remote", "llama-3.3-70b-versatile"), option("remote", "playai-tts")],
            remoteConfigured: true))

        XCTAssertEqual(models.map(\.option.identifier), ["whisper-large-v3-turbo"])
        XCTAssertEqual(models.map(\.family), [.remote])
    }

    func testUnconfiguredRemoteOffersNothingEvenWithACachedList() {
        let models = RegenerationModels.usable(.init(
            remote: [option("remote", "whisper-1")], remoteConfigured: false))

        XCTAssertTrue(models.isEmpty)
    }

    func testNothingInstalledOffersNothing() {
        XCTAssertTrue(RegenerationModels.usable(.init()).isEmpty)
    }

    func testEveryInstalledFamilyIsKeptAndGroupedInPickerOrder() {
        let models = RegenerationModels.usable(.init(
            parakeet: [option("fluidaudio", "v3")],
            whisper: [option("whisper", "/models/ggml-base.bin"), option("whisper", "/models/ggml-small.bin")],
            senseVoice: [option("sensevoice", "default")],
            appleSpeech: [option("apple", "default")],
            remote: [option("remote", "whisper-1")],
            remoteConfigured: true))

        XCTAssertEqual(models.map(\.family),
                       [.parakeet, .whisper, .whisper, .senseVoice, .appleSpeech, .remote])
        XCTAssertEqual(models.map(\.option.identifier),
                       ["v3", "/models/ggml-base.bin", "/models/ggml-small.bin", "default", "default", "whisper-1"])
    }

    func testAppleSpeechNeedsItsAssetsForTheLanguage() {
        XCTAssertTrue(ModelCatalog.appleSpeechModels(forLanguage: "zz-no-such-language").isEmpty)
    }
}
