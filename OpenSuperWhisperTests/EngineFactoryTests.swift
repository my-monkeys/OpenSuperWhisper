import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Which engine `TranscriptionService` builds for each stored engine id, and for the model the
/// remote engine falls back to.
///
/// The ids are persisted in every user's preferences, and the extraction moved the factory into
/// the core with new platform gates (`os(macOS) && arch(arm64)`, iOS 26 availability). Each id
/// and each fallback is pinned here so no later change quietly sends a user to another engine.
final class EngineFactoryTests: XCTestCase {

    private typealias Kind = TranscriptionService.EngineKind

    private func kind(_ id: String, senseVoice: Bool = true, appleSpeech: Bool = true) -> Kind {
        TranscriptionService.engineKind(forSelectedEngine: id,
                                        senseVoiceAvailable: senseVoice,
                                        appleSpeechAvailable: appleSpeech)
    }

    func testEveryPersistedIdGetsItsEngine() {
        XCTAssertEqual(kind("whisper"), .whisper)
        XCTAssertEqual(kind("fluidaudio"), .fluidAudio)
        XCTAssertEqual(kind("sensevoice"), .senseVoice)
        XCTAssertEqual(kind("remote"), .remote)
        XCTAssertEqual(kind("apple"), .appleSpeech)
    }

    /// SenseVoice ships arm64 only; an Intel Mac that synced the pref gets Whisper.
    func testSenseVoiceFallsBackToWhisperWhereItIsNotCompiled() {
        XCTAssertEqual(kind("sensevoice", senseVoice: false), .whisper)
    }

    /// Apple Speech needs macOS 26; an older Mac that synced the pref gets Whisper.
    func testAppleSpeechFallsBackToWhisperBelowMacOS26() {
        XCTAssertEqual(kind("apple", appleSpeech: false), .whisper)
    }

    /// The gates only affect their own engine.
    func testGatesDoNotTouchOtherIds() {
        for id in ["whisper", "fluidaudio", "remote"] {
            XCTAssertEqual(kind(id, senseVoice: false, appleSpeech: false), kind(id), id)
        }
    }

    /// Anything else falls back to Whisper instead of failing to load, including the Groq id
    /// that predates the remote engine. AppPreferences rewrites "groq" to "remote" when it is
    /// built, so a "groq" written after that (a restored backup, say) gets Whisper, not the
    /// remote engine, until the next launch. Pinned as it is.
    func testUnknownAndLegacyIdsFallBackToWhisper() {
        for id in ["groq", "", "Whisper", "WHISPER", "parakeet", "sense-voice", " whisper"] {
            XCTAssertEqual(kind(id), .whisper, "'\(id)'")
        }
    }

    /// The defaults are the gates the app evaluates. The test host is an arm64 build on this
    /// branch's macOS, so both are open here; the branches above cover the closed side.
    func testDefaultGatesMatchThisBuild() {
#if arch(arm64)
        XCTAssertTrue(TranscriptionService.isSenseVoiceCompiled)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "sensevoice"), .senseVoice)
#else
        XCTAssertFalse(TranscriptionService.isSenseVoiceCompiled)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "sensevoice"), .whisper)
#endif
        var appleSpeechExpected = false
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) { appleSpeechExpected = true }
#endif
        XCTAssertEqual(TranscriptionService.isAppleSpeechAvailable, appleSpeechExpected)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "apple"),
                       appleSpeechExpected ? .appleSpeech : .whisper)
    }

    // MARK: Building

    /// The kind decides the class. Built, never initialized: no model is loaded or downloaded.
    /// A move that sent one kind to another engine's class would pass the mapping tests above.
    func testEachKindBuildsItsEngineClass() async {
        let whisper = await TranscriptionService.buildEngine(.whisper)
        XCTAssertTrue(whisper is WhisperEngine)
        XCTAssertNil((whisper as? WhisperEngine)?.modelPathOverride, "the loader uses the selected model")
        let fluid = await TranscriptionService.buildEngine(.fluidAudio)
        XCTAssertNil((fluid as? FluidAudioEngine)?.versionOverride, "the loader uses the selected version")
        XCTAssertTrue(fluid is FluidAudioEngine)
        let remote = await TranscriptionService.buildEngine(.remote)
        XCTAssertTrue(remote is RemoteEngine)
#if arch(arm64)
        let senseVoice = await TranscriptionService.buildEngine(.senseVoice)
        XCTAssertTrue(senseVoice is SenseVoiceEngine)
#endif
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let apple = await TranscriptionService.buildEngine(.appleSpeech)
            XCTAssertTrue(apple is AppleSpeechEngine)
        }
#endif
    }

    // MARK: Remote local-fallback

    private typealias Choice = TranscriptionService.FallbackEngineChoice

    private func choice(_ engine: String, _ identifier: String,
                        senseVoice: Bool = true, appleSpeech: Bool = true) -> Choice {
        TranscriptionService.fallbackEngineChoice(
            for: DictationModelOption(engine: engine, identifier: identifier, displayName: "x"),
            senseVoiceAvailable: senseVoice, appleSpeechAvailable: appleSpeech)
    }

    /// The fallback factory is a second mapping, keyed on the fallback model's engine and handing
    /// its identifier to the engine. It moved with the service in slice 4.
    func testFallbackModelGetsItsEngineAndIdentifier() {
        XCTAssertEqual(choice("whisper", "/models/ggml-base.bin"), .whisper(modelPathOverride: "/models/ggml-base.bin"))
        XCTAssertEqual(choice("fluidaudio", "v3"), .fluidAudio(version: "v3"))
        XCTAssertEqual(choice("fluidaudio", "ultra"), .fluidAudio(version: "ultra"))
        XCTAssertEqual(choice("apple", "default"), .appleSpeech)
    }

    /// SenseVoice has one model, so where it is compiled the identifier is ignored.
    func testFallbackSenseVoiceIgnoresTheIdentifier() {
        XCTAssertEqual(choice("sensevoice", "default"), .senseVoice)
        XCTAssertEqual(choice("sensevoice", "anything"), .senseVoice)
    }

    /// Suspicious, pinned as is: unlike the loader, which builds Whisper with the selected model,
    /// the Intel fallback hands SenseVoice's identifier ("default" in the catalog) to Whisper as a
    /// model path, which cannot load.
    func testFallbackSenseVoiceWithoutSenseVoicePassesItsIdentifierToWhisper() {
        XCTAssertEqual(choice("sensevoice", "default", senseVoice: false), .whisper(modelPathOverride: "default"))
    }

    /// Below macOS 26, "apple" gets Whisper with no override, so the user's selected Whisper model,
    /// not the "default" identifier the catalog gives Apple Speech.
    func testFallbackAppleSpeechWithoutAppleSpeechUsesTheSelectedWhisperModel() {
        XCTAssertEqual(choice("apple", "default", appleSpeech: false), .whisper(modelPathOverride: nil))
    }

    /// Suspicious, pinned as is: every other engine, "remote" included, passes its identifier to
    /// Whisper as a model path. A remote model id (say "whisper-1") cannot load.
    func testFallbackUnknownEnginesPassTheirIdentifierToWhisper() {
        XCTAssertEqual(choice("remote", "whisper-1"), .whisper(modelPathOverride: "whisper-1"))
        XCTAssertEqual(choice("groq", "x"), .whisper(modelPathOverride: "x"))
        XCTAssertEqual(choice("", ""), .whisper(modelPathOverride: ""))
        XCTAssertEqual(choice("Whisper", "/m.bin"), .whisper(modelPathOverride: "/m.bin"))
    }

    /// The gates only affect their own engine.
    func testFallbackGatesDoNotTouchOtherEngines() {
        for (engine, id) in [("whisper", "/m.bin"), ("fluidaudio", "v2"), ("remote", "m")] {
            XCTAssertEqual(choice(engine, id, senseVoice: false, appleSpeech: false), choice(engine, id), engine)
        }
    }

    /// The choice reaches the engine unchanged: the class, and the path or version it is given.
    func testFallbackChoiceBuildsItsEngineWithItsArgument() async {
        let whisper = await TranscriptionService.buildFallbackEngine(.whisper(modelPathOverride: "/m.bin"))
        XCTAssertEqual((whisper as? WhisperEngine)?.modelPathOverride, "/m.bin")
        let selectedWhisper = await TranscriptionService.buildFallbackEngine(.whisper(modelPathOverride: nil))
        XCTAssertTrue(selectedWhisper is WhisperEngine)
        XCTAssertNil((selectedWhisper as? WhisperEngine)?.modelPathOverride)
        let fluid = await TranscriptionService.buildFallbackEngine(.fluidAudio(version: "v2"))
        XCTAssertEqual((fluid as? FluidAudioEngine)?.versionOverride, "v2")
#if arch(arm64)
        let senseVoice = await TranscriptionService.buildFallbackEngine(.senseVoice)
        XCTAssertTrue(senseVoice is SenseVoiceEngine)
#endif
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let apple = await TranscriptionService.buildFallbackEngine(.appleSpeech)
            XCTAssertTrue(apple is AppleSpeechEngine)
        }
#endif
    }
}
