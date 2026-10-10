import XCTest
@testable import OpenSuperWhisperCore

/// The engine gates as each platform compiles them. The hosted `EngineFactoryTests` pins the
/// macOS app build; this is the port that also holds on iOS, where SenseVoice is not compiled and
/// a synced "sensevoice" preference must land on Whisper.
final class PlatformAvailabilityTests: CoreTestCase {

    private var expectsSenseVoice: Bool {
#if os(macOS) && arch(arm64)
        return true
#else
        return false
#endif
    }

    private var expectsAppleSpeech: Bool {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return true }
#endif
        return false
    }

    func testSenseVoiceIsCompiledOnlyOnAppleSiliconMacs() {
        XCTAssertEqual(TranscriptionService.isSenseVoiceCompiled, expectsSenseVoice)
    }

    func testAppleSpeechIsGatedOnMacOS26AndIOS26() {
        XCTAssertEqual(TranscriptionService.isAppleSpeechAvailable, expectsAppleSpeech)
#if targetEnvironment(simulator)
        XCTAssertTrue(TranscriptionService.isAppleSpeechAvailable, "the 26.5 and 27.0 simulators run iOS 26 or later")
#endif
    }

    func testDefaultGatesRouteSenseVoice() {
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "sensevoice"),
                       expectsSenseVoice ? .senseVoice : .whisper)
    }

    /// The catalog lists SenseVoice only once its two files are on disk, so the test stages empty
    /// files under those names in the test storage root: then compiling is the only gate left.
    func testSenseVoiceModelsAreListedOnlyWhereCompiled() throws {
        let manager = SenseVoiceModelManager.shared
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager.modelDirectory) }
        for file in [manager.modelPath, manager.tokensPath] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        }

        XCTAssertEqual(ModelCatalog.senseVoiceModels().isEmpty, !TranscriptionService.isSenseVoiceCompiled)
    }

    /// Built, never initialised: no model is loaded or downloaded.
    func testEachAvailableKindBuildsItsEngineClass() async {
        let whisper = await TranscriptionService.buildEngine(.whisper)
        XCTAssertTrue(whisper is WhisperEngine)
        let fluid = await TranscriptionService.buildEngine(.fluidAudio)
        XCTAssertTrue(fluid is FluidAudioEngine)
        let remote = await TranscriptionService.buildEngine(.remote)
        XCTAssertTrue(remote is RemoteEngine)
#if os(macOS) && arch(arm64)
        let senseVoice = await TranscriptionService.buildEngine(.senseVoice)
        XCTAssertTrue(senseVoice is SenseVoiceEngine)
#endif
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let apple = await TranscriptionService.buildEngine(.appleSpeech)
            XCTAssertTrue(apple is AppleSpeechEngine)
        }
#endif
    }
}
