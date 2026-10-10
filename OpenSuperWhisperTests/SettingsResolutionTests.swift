import XCTest

@testable import OpenSuperWhisper

/// What `Settings()` resolves from preferences, the keyboard layout and the prompt file.
///
/// The file-drop queue, the CLI and the main-window recorder all build their transcription
/// settings this way, and it becomes the app-side initialiser of the core's settings type.
/// `PromptFileTests` covers reading the file on its own; these pin the precedence once the
/// file and the preferences meet, and every field the initialiser copies. Under tests
/// `Settings.promptFileURL` is inside the private storage root, so writing it is safe.
final class SettingsResolutionTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private var promptFile: URL { Settings.promptFileURL }

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = ScratchPreferences()
        try? FileManager.default.removeItem(at: promptFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: promptFile)
        scratch.restore()
        try super.tearDownWithError()
    }

    private func writePrompt(_ text: String) throws {
        try FileManager.default.createDirectory(at: promptFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: promptFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Prompt

    func testPromptFileWinsOverThePreference() throws {
        prefs.initialPrompt = "typed in Settings"
        try writePrompt("\n  From the file.\nSecond line.  \n")

        XCTAssertEqual(Settings().initialPrompt, "From the file.\nSecond line.")
    }

    func testNoPromptFileUsesThePreference() {
        prefs.initialPrompt = "typed in Settings"
        XCTAssertEqual(Settings().initialPrompt, "typed in Settings")
    }

    func testEmptyOrBlankPromptFileFallsBackToThePreference() throws {
        prefs.initialPrompt = "typed in Settings"
        for blank in ["", " ", "\n\n\t  \n"] {
            try writePrompt(blank)
            XCTAssertEqual(Settings().initialPrompt, "typed in Settings", "file: \(blank.debugDescription)")
        }
    }

    /// The preference is used as typed: unlike the file it is not trimmed.
    func testThePreferenceIsNotTrimmed() {
        prefs.initialPrompt = "  spaced \n"
        XCTAssertEqual(Settings().initialPrompt, "  spaced \n")
    }

    func testPromptFileIsCappedAt16KiB() throws {
        XCTAssertEqual(Settings.promptFileByteLimit, 16_384)
        try writePrompt(String(repeating: "a", count: 40_000))

        XCTAssertEqual(Settings().initialPrompt.utf8.count, 16_384)
    }

    /// Suspicious, pinned as it is: the cap counts bytes, and a cut through a multi-byte
    /// character makes the whole read invalid UTF-8, so the file is ignored entirely and the
    /// typed prompt is used instead of the first 16 KiB of the file.
    func testCapThatSplitsACharacterIgnoresTheWholeFile() throws {
        prefs.initialPrompt = "typed in Settings"
        try writePrompt(String(repeating: "a", count: 16_383) + "é and more")

        XCTAssertEqual(Settings().initialPrompt, "typed in Settings")
    }

    // MARK: - Language

    /// A stored language reaches the engine as is, without checking the engine supports it.
    func testFixedLanguagePassesThrough() {
        for (engine, language) in [("whisper", "fr"), ("whisper", "auto"), ("fluidaudio", "ja"),
                                   ("remote", "pt"), ("sensevoice", "de")] {
            prefs.selectedEngine = engine
            prefs.fluidAudioModelVersion = "v2"
            prefs.whisperLanguage = language
            XCTAssertEqual(Settings().selectedLanguage, language, "\(engine)/\(language)")
        }
    }

    /// "keyboard" is a way of choosing a language, never a language. It resolves to the active
    /// layout's language if the engine supports it, else "auto". The layout is this machine's,
    /// so the test pins the property (never "keyboard", always "auto" or a supported code) and
    /// the formula, not a particular language.
    func testKeyboardPseudoLanguageNeverLeaks() {
        prefs.whisperLanguage = KeyboardLanguage.selectionCode
        let engines = [("whisper", "v3"), ("fluidaudio", "v2"), ("fluidaudio", "v3"),
                       ("sensevoice", "v3"), ("apple", "v3"), ("remote", "v3")]
        for (engine, version) in engines {
            prefs.selectedEngine = engine
            prefs.fluidAudioModelVersion = version

            let language = Settings().selectedLanguage

            XCTAssertNotEqual(language, "keyboard", engine)
            let supported = EngineCapabilities.supportedLanguages(engine: engine, fluidAudioModelVersion: version)
            XCTAssertTrue(language == "auto" || supported.contains(language), "\(engine): \(language)")
            XCTAssertEqual(language,
                           KeyboardLanguage.current(engine: engine, fluidAudioModelVersion: version) ?? "auto",
                           engine)
        }
        XCTAssertEqual(KeyboardLanguage.selectionCode, "keyboard", "stored in whisperLanguage")
    }

    // MARK: - Every field

    func testEveryFieldIsCopiedFromThePreferences() {
        let entry = CustomDictionaryEntry(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!,
                                          original: "osw", replacement: "OpenSuperWhisper",
                                          alternates: ["o s w"], spacing: .standalone, isRegex: false)
        prefs.selectedEngine = "whisper"
        prefs.whisperLanguage = "ja"
        prefs.translateToEnglish = true
        prefs.suppressBlankAudio = false
        prefs.showTimestamps = true
        prefs.temperature = 0.4
        prefs.noSpeechThreshold = 0.35
        prefs.initialPrompt = "Prompt."
        prefs.useBeamSearch = true
        prefs.beamSize = 3
        prefs.useAsianAutocorrect = false
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryBoostEnabled = true
        prefs.customDictionaryEntries = [entry]
        prefs.useSurroundingTextAsContext = true

        let settings = Settings()

        XCTAssertEqual(settings.selectedLanguage, "ja")
        XCTAssertEqual(settings.translateToEnglish, true)
        XCTAssertEqual(settings.suppressBlankAudio, false)
        XCTAssertEqual(settings.showTimestamps, true)
        XCTAssertEqual(settings.temperature, 0.4)
        XCTAssertEqual(settings.noSpeechThreshold, 0.35)
        XCTAssertEqual(settings.initialPrompt, "Prompt.")
        XCTAssertEqual(settings.useBeamSearch, true)
        XCTAssertEqual(settings.beamSize, 3)
        XCTAssertEqual(settings.useAsianAutocorrect, false)
        XCTAssertEqual(settings.customDictionaryEnabled, true)
        XCTAssertEqual(settings.customDictionaryBoostEnabled, true)
        XCTAssertEqual(settings.customDictionaryEntries, [entry])
        XCTAssertEqual(settings.useSurroundingTextAsContext, true)
        XCTAssertNil(settings.focusedText, "set per clip by the pipeline, never from preferences")

        XCTAssertTrue(settings.isAsianLanguage)
        XCTAssertFalse(settings.shouldApplyAsianAutocorrect)
        XCTAssertTrue(settings.shouldApplyCustomDictionary)
        XCTAssertTrue(settings.shouldBoostCustomDictionary)
    }

    /// The values a fresh install transcribes with.
    func testFreshInstallSettings() {
        let settings = Settings()

        XCTAssertEqual(settings.selectedLanguage, "en")
        XCTAssertEqual(settings.translateToEnglish, false)
        XCTAssertEqual(settings.suppressBlankAudio, true)
        XCTAssertEqual(settings.showTimestamps, false)
        XCTAssertEqual(settings.temperature, 0.0)
        XCTAssertEqual(settings.noSpeechThreshold, 0.6)
        XCTAssertEqual(settings.initialPrompt, "")
        XCTAssertEqual(settings.useBeamSearch, false)
        XCTAssertEqual(settings.beamSize, 5)
        XCTAssertEqual(settings.useAsianAutocorrect, true)
        XCTAssertEqual(settings.customDictionaryEnabled, false)
        XCTAssertEqual(settings.customDictionaryBoostEnabled, false)
        XCTAssertEqual(settings.customDictionaryEntries, [])
        XCTAssertEqual(settings.useSurroundingTextAsContext, false)
        XCTAssertNil(settings.focusedText)
        XCTAssertFalse(settings.shouldApplyCustomDictionary)
    }

    /// Boosting needs the dictionary itself on and non-empty, whatever its own switch says.
    func testBoostNeedsAnEnabledNonEmptyDictionary() {
        prefs.customDictionaryBoostEnabled = true
        prefs.customDictionaryEnabled = true
        XCTAssertFalse(Settings().shouldBoostCustomDictionary, "empty dictionary")

        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "a", replacement: "b")]
        prefs.customDictionaryEnabled = false
        XCTAssertFalse(Settings().shouldBoostCustomDictionary, "dictionary off")
    }
}
