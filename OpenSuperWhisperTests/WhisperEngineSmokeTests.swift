import XCTest
@testable import OpenSuperWhisper

/// Commit 0, scenario 5: the engine file-injection smoke — the ONLY commit-0 test that
/// drives real whisper.cpp inference. App-hosted (dylibs load from the host app), model
/// and fixture located via #filePath-derived repo root (compile-time path: valid because
/// the gate always builds and tests on the same checkout; a moved tree fails LOUDLY in
/// setUp, never silently).
///
/// Also carries the INFORMATIONAL bench baseline (`testBenchBaselineTranscription`) —
/// wall-clock, printed only, NEVER asserted. The 0.7 whisper.cpp-bump gate and the
/// commit-2 extraction gate compare against the HANDOFF-recorded number (>20% band at
/// comparison time, per plan).
final class WhisperEngineSmokeTests: XCTestCase {

    /// Repo root = two levels up from this file (<root>/OpenSuperWhisperTests/ThisFile.swift).
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var modelPath: String { Self.repoRoot.appendingPathComponent("ggml-tiny.en.bin").path }
    private var fixtureURL: URL { Self.repoRoot.appendingPathComponent("jfk.wav") }

    private var prefs: AppPreferences { AppPreferences.shared }
    private var saved: (
        language: String, translate: Bool, timestamps: Bool, beam: Bool, beamSize: Int,
        temperature: Double, noSpeech: Double, prompt: String, suppressBlank: Bool,
        asianAutocorrect: Bool, dictEnabled: Bool, dictBoost: Bool, dictData: Data?,
        unloadWhenIdle: Bool
    )!

    override func setUp() {
        super.setUp()
        saved = (
            prefs.whisperLanguage, prefs.translateToEnglish, prefs.showTimestamps,
            prefs.useBeamSearch, prefs.beamSize, prefs.temperature, prefs.noSpeechThreshold,
            prefs.initialPrompt, prefs.suppressBlankAudio, prefs.useAsianAutocorrect,
            prefs.customDictionaryEnabled, prefs.customDictionaryBoostEnabled,
            UserDefaults.standard.data(forKey: "customDictionaryData"),
            prefs.unloadWhisperModelWhenIdle
        )

        // Deterministic transcription context: greedy, English, no prompt shaping,
        // no post-processing, model stays loaded.
        prefs.whisperLanguage = "en"
        prefs.translateToEnglish = false
        prefs.showTimestamps = false
        prefs.useBeamSearch = false
        prefs.temperature = 0.0
        prefs.noSpeechThreshold = 0.6
        prefs.initialPrompt = ""
        prefs.suppressBlankAudio = true
        prefs.useAsianAutocorrect = false
        prefs.customDictionaryEnabled = false
        prefs.customDictionaryBoostEnabled = false
        prefs.unloadWhisperModelWhenIdle = false

        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath),
                      "ggml-tiny.en.bin must exist at repo root (compile-time #filePath: \(modelPath))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path),
                      "jfk.wav must exist at repo root (compile-time #filePath: \(fixtureURL.path))")
    }

    override func tearDown() {
        prefs.whisperLanguage = saved.language
        prefs.translateToEnglish = saved.translate
        prefs.showTimestamps = saved.timestamps
        prefs.useBeamSearch = saved.beam
        prefs.beamSize = saved.beamSize
        prefs.temperature = saved.temperature
        prefs.noSpeechThreshold = saved.noSpeech
        prefs.initialPrompt = saved.prompt
        prefs.suppressBlankAudio = saved.suppressBlank
        prefs.useAsianAutocorrect = saved.asianAutocorrect
        prefs.customDictionaryEnabled = saved.dictEnabled
        prefs.customDictionaryBoostEnabled = saved.dictBoost
        if let data = saved.dictData {
            UserDefaults.standard.set(data, forKey: "customDictionaryData")
        } else {
            UserDefaults.standard.removeObject(forKey: "customDictionaryData")
        }
        prefs.unloadWhisperModelWhenIdle = saved.unloadWhenIdle
        super.tearDown()
    }

    private func makeLoadedEngine() async throws -> WhisperEngine {
        let engine = WhisperEngine(modelPathOverride: modelPath)
        try await engine.initialize()
        return engine
    }

    func testTinyEnTranscribesBundledSpeech() async throws {
        let engine = try await makeLoadedEngine()
        XCTAssertTrue(engine.isModelLoaded, "initialize() must leave the model loaded (unloadWhenIdle off)")

        let text = try await engine.transcribeAudio(url: fixtureURL, settings: Settings())

        XCTAssertFalse(text.isEmpty, "whisper must return text for 11s of clear English speech")
        XCTAssertNotEqual(text, TranscriptionResult.noSpeech,
                          "clear speech must not hit the no-speech sentinel")
        // Characterization anchor: the actual tiny.en output on this fixture (observed
        // 2026-07-19) contains the opening of the JFK address. Loose on purpose — the
        // pin is "same engine, same fixture → same ballpark text", not a WER score.
        let lowered = text.lowercased()
        XCTAssertTrue(
            lowered.contains("ask not") || lowered.contains("country") || lowered.contains("fellow americans"),
            "expected a recognizable JFK-address fragment, got: \(text.prefix(200))"
        )
    }

    func testTranscribeOfTruncatedWavThrowsAudioConversionFailed() async throws {
        // Companion edge pin: a corrupt/truncated audio file must surface as
        // audioConversionFailed, not a crash and not phantom text.
        let engine = try await makeLoadedEngine()
        let truncated = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSWTests-truncated-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: truncated) }

        let data = try Data(contentsOf: fixtureURL)
        try data.prefix(64).write(to: truncated)  // WAV header fragment, no usable stream

        do {
            _ = try await engine.transcribeAudio(url: truncated, settings: Settings())
            XCTFail("truncated wav should throw audioConversionFailed")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .audioConversionFailed)
        }
    }

    /// INFORMATIONAL BENCH BASELINE — never asserted. Written to a run-local file (the
    /// hosted test process's stdout does NOT reach the xcodebuild log) and recorded in
    /// the HANDOFF; compared (not gated) at the 0.7 bump and commit-2 gates (>20% band).
    func testBenchBaselineTranscription() async throws {
        let engine = try await makeLoadedEngine()  // model hot — measures inference, not load
        let start = ContinuousClock.now
        let text = try await engine.transcribeAudio(url: fixtureURL, settings: Settings())
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let line = "[BENCH-BASELINE] whisper tiny.en jfk.wav (11s audio, greedy, model hot): \(String(format: "%.3f", seconds))s wall"
        print(line)
        let capture = "\(line)\nobserved-output-head: \(text.prefix(160))\n"
        try? capture.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commit0-bench-baseline.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "bench run must be a valid transcription")
    }
}
