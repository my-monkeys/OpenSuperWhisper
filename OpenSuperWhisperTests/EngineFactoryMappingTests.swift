import XCTest
@testable import WhisperCore
@testable import OpenSuperWhisper

/// Commit 0, scenario 1: pin the engine-kind factory mapping behind
/// `TranscriptionService.makeEngine` — every arm of the former inline string-switch,
/// including the two fallback arms (sensevoice→whisper, apple→whisper) that are only
/// reachable on arm64 by injecting `EnginePlatformGates` with the capability off.
///
/// Contract under test: construction only. Engines come back UN-initialized (no model
/// download, no model load), so these tests touch neither disk nor network.
final class EngineFactoryMappingTests: XCTestCase {

    private let gatesAll = EnginePlatformGates(supportsSenseVoice: true, supportsAppleSpeech: true)
    private let gatesNone = EnginePlatformGates(supportsSenseVoice: false, supportsAppleSpeech: false)

    // MARK: - makeEngine(selectedEngine:)

    func testWhisperAndUnknownStringsBuildWhisperEngine() async {
        // "groq" is the legacy pre-remote engine id; today it must fall into the default arm.
        for selection in ["whisper", "", "bogus", "groq"] {
            let engine = await TranscriptionService.makeEngine(selectedEngine: selection, gates: gatesAll)
            XCTAssertTrue(engine is WhisperEngine, "\"\(selection)\" should map to WhisperEngine")
            XCTAssertEqual(engine?.engineName, "Whisper")
        }
    }

    func testFluidaudioBuildsFluidAudioEngine() async {
        let engine = await TranscriptionService.makeEngine(selectedEngine: "fluidaudio", gates: gatesAll)
        XCTAssertTrue(engine is FluidAudioEngine)
        XCTAssertEqual(engine?.engineName, "FluidAudio")
    }

    func testRemoteBuildsRemoteEngine() async {
        let engine = await TranscriptionService.makeEngine(selectedEngine: "remote", gates: gatesAll)
        XCTAssertTrue(engine is RemoteEngine)
        XCTAssertEqual(engine?.engineName, "Remote")
    }

    func testSensevoiceArmFollowsTheSenseVoiceGate() async {
        #if arch(arm64)
        let gated = await TranscriptionService.makeEngine(selectedEngine: "sensevoice", gates: gatesAll)
        XCTAssertTrue(gated is SenseVoiceEngine, "arm64 + supportsSenseVoice should build SenseVoiceEngine")

        // The x86_64 production fallback, reproduced on arm64 by gating off.
        let ungated = await TranscriptionService.makeEngine(selectedEngine: "sensevoice", gates: gatesNone)
        XCTAssertTrue(ungated is WhisperEngine, "supportsSenseVoice=false should fall back to WhisperEngine")
        #else
        // On Intel the arm ignores gates entirely: always whisper.
        for gates in [gatesAll, gatesNone] {
            let engine = await TranscriptionService.makeEngine(selectedEngine: "sensevoice", gates: gates)
            XCTAssertTrue(engine is WhisperEngine, "x86_64 sensevoice always falls back to WhisperEngine")
        }
        #endif
    }

    func testAppleArmFollowsTheAppleSpeechGate() async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let gated = await TranscriptionService.makeEngine(selectedEngine: "apple", gates: gatesAll)
            XCTAssertTrue(gated is AppleSpeechEngine, "macOS 26 + supportsAppleSpeech should build AppleSpeechEngine")

            // A pref synced from a machine without Apple Speech support: quiet whisper fallback.
            let ungated = await TranscriptionService.makeEngine(selectedEngine: "apple", gates: gatesNone)
            XCTAssertTrue(ungated is WhisperEngine, "supportsAppleSpeech=false should fall back to WhisperEngine")
            return
        }
        #endif
        // No FoundationModels in the SDK, or a pre-26 host: apple always falls back.
        let engine = await TranscriptionService.makeEngine(selectedEngine: "apple", gates: gatesAll)
        XCTAssertTrue(engine is WhisperEngine, "apple without platform support should fall back to WhisperEngine")
    }

    // MARK: - makeEngine(modelOption:)

    func testModelOptionWhisperArmUsesPathOverride() async {
        let option = DictationModelOption(engine: "whisper", identifier: "/tmp/whatever.bin", displayName: "whatever")
        let engine = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(engine is WhisperEngine)
    }

    func testModelOptionFluidaudioArm() async {
        let option = DictationModelOption(engine: "fluidaudio", identifier: "v3", displayName: "Parakeet v3")
        let engine = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(engine is FluidAudioEngine)
    }

    func testModelOptionRemoteFallsIntoDefaultWhisperArm() async {
        // DictationModelOption.engine is documented as whisper|fluidaudio|sensevoice|remote —
        // but the modelOption switch has NO remote case: "remote" hits default → whisper.
        // Pin that asymmetry vs makeEngine(selectedEngine:) exactly as it behaves today.
        let option = DictationModelOption(engine: "remote", identifier: "whisper-large-v3", displayName: "remote")
        let engine = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(engine is WhisperEngine,
                      "modelOption has no remote arm — pin the default-to-whisper behavior")
    }

    func testModelOptionSensevoiceArmFollowsGateOnArm64() async {
        let option = DictationModelOption(engine: "sensevoice", identifier: "default", displayName: "SenseVoice")
        #if arch(arm64)
        let gated = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(gated is SenseVoiceEngine)
        let ungated = await TranscriptionService.makeEngine(modelOption: option, gates: gatesNone)
        XCTAssertTrue(ungated is WhisperEngine, "gated-off sensevoice model option falls back to whisper")
        #else
        let engine = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(engine is WhisperEngine)
        #endif
    }

    func testModelOptionAppleArmFollowsGateAndAvailability() async {
        let option = DictationModelOption(engine: "apple", identifier: "default", displayName: "Apple Speech")
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let gated = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
            XCTAssertTrue(gated is AppleSpeechEngine)
            let ungated = await TranscriptionService.makeEngine(modelOption: option, gates: gatesNone)
            XCTAssertTrue(ungated is WhisperEngine)
            return
        }
        #endif
        let engine = await TranscriptionService.makeEngine(modelOption: option, gates: gatesAll)
        XCTAssertTrue(engine is WhisperEngine)
    }

    // MARK: - Gates oracle

    func testCurrentGatesMatchThisHost() {
        // `.current` must reproduce the compile-time/runtime truth the inline chain used.
        let current = EnginePlatformGates.current
        #if arch(arm64)
        XCTAssertTrue(current.supportsSenseVoice, "arm64 host must report supportsSenseVoice")
        #else
        XCTAssertFalse(current.supportsSenseVoice, "x86_64 host must not report supportsSenseVoice")
        #endif
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(current.supportsAppleSpeech)
        } else {
            XCTAssertFalse(current.supportsAppleSpeech)
        }
        #else
        XCTAssertFalse(current.supportsAppleSpeech)
        #endif
    }
}
