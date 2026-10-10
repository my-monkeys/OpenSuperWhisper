import XCTest
@testable import OpenSuperWhisper

/// Which engine `TranscriptionService` builds for each stored engine id.
///
/// The ids are persisted in every user's preferences, and the extraction moves the factory into
/// the core with new platform gates (`os(macOS) && arch(arm64)`, iOS 26 availability). Each id
/// and each fallback is pinned here so the move cannot quietly send a user to another engine.
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
}
