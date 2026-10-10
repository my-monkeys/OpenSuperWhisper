import XCTest

@testable import OpenSuperWhisper

/// The `transcribe` and `bench` command lines, and the settings they hand the engine.
///
/// `--model` and `--raw` exist for `Scripts/smoke-release.sh`, which compares a release build's
/// transcript with a recorded one: that only means something if nothing on the machine running
/// it can change the input. The calls without them must keep behaving as before, unknown words
/// included, because the Homebrew CLI and people's scripts already depend on them.
final class CLIInvocationTests: XCTestCase {

    private func parse(_ words: String...) -> CLI.Invocation? {
        CLI.parseInvocation(["OpenSuperWhisper"] + words)
    }

    // MARK: - Parsing

    func testAPlainCallParsesToTheDefaults() {
        XCTAssertEqual(parse("transcribe", "a.wav"), CLI.Invocation(mode: .transcribe, target: "a.wav"))
        XCTAssertEqual(parse("bench", "dir"), CLI.Invocation(mode: .bench, target: "dir"))
    }

    func testJSONIsFoundAnywhereAfterTheFile() {
        XCTAssertEqual(parse("transcribe", "a.wav", "--json")?.json, true)
        XCTAssertEqual(parse("transcribe", "a.wav", "--raw", "--json")?.json, true)
    }

    /// The parser used to look for `--json` and nothing else, so anything else was ignored.
    func testUnknownWordsAreStillIgnored() {
        XCTAssertEqual(parse("transcribe", "a.wav", "--verbose", "extra"),
                       CLI.Invocation(mode: .transcribe, target: "a.wav"))
    }

    func testEveryOptionTogether() {
        let expected = CLI.Invocation(mode: .transcribe, target: "a.wav", json: true,
                                      modelPath: "/m/ggml-tiny.en.bin", raw: true)
        XCTAssertEqual(parse("transcribe", "a.wav", "--model", "/m/ggml-tiny.en.bin",
                             "--raw", "--json"), expected)
        XCTAssertEqual(parse("transcribe", "a.wav", "--json",
                             "--raw", "--model", "/m/ggml-tiny.en.bin"), expected)
    }

    func testBenchTakesTheSameOptions() {
        XCTAssertEqual(parse("bench", "dir", "--model", "m.bin", "--raw"),
                       CLI.Invocation(mode: .bench, target: "dir", modelPath: "m.bin", raw: true))
    }

    /// A missing value is a usage error, not an option silently swallowed as a file name.
    func testAnOptionWithoutItsValueIsRejected() {
        XCTAssertNil(parse("transcribe", "a.wav", "--model"))
        XCTAssertNil(parse("transcribe", "a.wav", "--model", "--raw"))
    }

    func testOtherCommandsAndAMissingTargetAreNotInvocations() {
        XCTAssertNil(parse("transcribe"))
        XCTAssertNil(parse("bench"))
        XCTAssertNil(parse("agent-hook", "x"))
        XCTAssertNil(parse("--help"))
        XCTAssertNil(CLI.parseInvocation(["OpenSuperWhisper"]))
    }

    func testHelpDocumentsTheNewOptions() {
        for option in ["--json", "--model", "--raw"] {
            XCTAssertTrue(CLI.usage.contains(option), option)
        }
    }
}

/// What the engine is told for each kind of call. Every preference that reaches `Settings` and
/// the prompt file are moved away from their defaults first, so a field that leaked through
/// `--raw` would show.
final class CLISettingsTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private var promptFile: URL { Settings.promptFileURL }

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = ScratchPreferences()
        prefs.whisperLanguage = "de"
        prefs.translateToEnglish = true
        prefs.suppressBlankAudio = false
        prefs.showTimestamps = true
        prefs.temperature = 0.4
        prefs.noSpeechThreshold = 0.2
        prefs.initialPrompt = "typed in Settings"
        prefs.useBeamSearch = true
        prefs.beamSize = 2
        prefs.useAsianAutocorrect = false
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryBoostEnabled = true
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        prefs.useSurroundingTextAsContext = true
        try FileManager.default.createDirectory(at: promptFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "From the prompt file.".write(to: promptFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: promptFile)
        scratch.restore()
        try super.tearDownWithError()
    }

    private func settings(_ words: String...) throws -> Settings {
        let invocation = try XCTUnwrap(CLI.parseInvocation(["OpenSuperWhisper", "transcribe", "a.wav"] + words))
        return CLI.settings(for: invocation)
    }

    /// Without `--raw` the call is what it always was: `Settings()`, preferences and prompt file
    /// included. This also shows the setup above really changed what `Settings()` returns.
    func testWithoutRawTheAppSettingsApply() throws {
        let settings = try settings()
        XCTAssertEqual(settings.selectedLanguage, "de")
        XCTAssertEqual(settings.initialPrompt, "From the prompt file.")
        XCTAssertTrue(settings.useBeamSearch)
        XCTAssertTrue(settings.shouldBoostCustomDictionary)
    }

    /// `--raw` gives exactly what the Whisper goldens are recorded with, so the release smoke
    /// check and `WhisperGoldenTests` expect the same transcript.
    func testRawIgnoresEveryPreferenceAndThePromptFile() throws {
        assertPinned(try settings("--raw"))
    }

    /// `--model` picks the engine, not the settings.
    func testModelAloneKeepsTheAppSettings() throws {
        XCTAssertEqual(try settings("--model", "m.bin").selectedLanguage, "de")
    }

    private func assertPinned(_ settings: Settings, file: StaticString = #filePath, line: UInt = #line) {
        let pinned = Fixtures.pinnedSettings()
        XCTAssertEqual(settings.selectedLanguage, pinned.selectedLanguage, file: file, line: line)
        XCTAssertEqual(settings.translateToEnglish, pinned.translateToEnglish, file: file, line: line)
        XCTAssertEqual(settings.suppressBlankAudio, pinned.suppressBlankAudio, file: file, line: line)
        XCTAssertEqual(settings.showTimestamps, pinned.showTimestamps, file: file, line: line)
        XCTAssertEqual(settings.temperature, pinned.temperature, file: file, line: line)
        XCTAssertEqual(settings.noSpeechThreshold, pinned.noSpeechThreshold, file: file, line: line)
        XCTAssertEqual(settings.initialPrompt, pinned.initialPrompt, file: file, line: line)
        XCTAssertEqual(settings.useBeamSearch, pinned.useBeamSearch, file: file, line: line)
        XCTAssertEqual(settings.beamSize, pinned.beamSize, file: file, line: line)
        XCTAssertEqual(settings.useAsianAutocorrect, pinned.useAsianAutocorrect, file: file, line: line)
        XCTAssertEqual(settings.customDictionaryEnabled, pinned.customDictionaryEnabled, file: file, line: line)
        XCTAssertEqual(settings.customDictionaryBoostEnabled, pinned.customDictionaryBoostEnabled,
                       file: file, line: line)
        XCTAssertEqual(settings.customDictionaryEntries, pinned.customDictionaryEntries, file: file, line: line)
        XCTAssertEqual(settings.useSurroundingTextAsContext, pinned.useSurroundingTextAsContext,
                       file: file, line: line)
        XCTAssertEqual(settings.focusedText, pinned.focusedText, file: file, line: line)
    }
}
