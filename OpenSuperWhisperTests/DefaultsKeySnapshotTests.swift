import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Every UserDefaults key the app persists, pinned by name.
///
/// A preference is found again on the next launch only through its key string. Renaming one, or
/// dropping it while moving `AppPreferences` into a package, silently resets that setting for
/// every user, and nothing else in the suite would notice: the property still compiles and still
/// returns its default. So each accessor is written once and must land on exactly the key listed
/// here, and the complete set must equal the golden list.
final class DefaultsKeySnapshotTests: XCTestCase {

    /// The keys `AppPreferences` writes, sorted. Change this list only on purpose, with a
    /// migration for the users who already have the old key.
    static let goldenKeys = [
        "addSpaceAfterSentence",
        "agentAskOnPermission",
        "agentAskOnQuestion",
        "agentAskOnStop",
        "agentDisabledProjects",
        "agentEnabledKinds",
        "agentRecentProjects",
        "agentWaitSeconds",
        "aiBackend",
        "aiOllamaEndpoint",
        "aiOllamaModel",
        "aiPostProcessingClosing",
        "aiPostProcessingEnabled",
        "aiPostProcessingPrompt",
        "aiPostProcessingTranslation",
        "aiRemoteEndpoint",
        "aiRemoteModel",
        "appAppearance",
        "appContextFormattingEnabled",
        "appContextProfilesData",
        "appInsertionRulesData",
        "appModelRules",
        "autoCopyToClipboard",
        "autoPasteTranscription",
        "beamSize",
        "builtInModelFileName",
        "cachedRemoteModels",
        "clipboardRestoreDelayMs",
        "contextAwareModelMode",
        "customDictionaryBoostEnabled",
        "customDictionaryData",
        "customDictionaryEnabled",
        "debugMode",
        "didSeedAppContextPresets",
        "escCancelWithoutConfirmation",
        "fillerWordsPattern",
        "fluidAudioModelVersion",
        "glassBubbleSize",
        "groqModel",
        "hasCompletedOnboarding",
        "holdRecordingTriggers",
        "holdToRecord",
        "indicatorCustomAnchor",
        "indicatorLayout",
        "indicatorMeterMode",
        "indicatorPosition",
        "initialPrompt",
        "lastModifierOnlyHotkey",
        "lastMouseButtonHotkey",
        "latchRecordingWithSpace",
        "liveTranscriptionEnabled",
        "modifierOnlyHotkey",
        "mouseButtonHotkey",
        "noSpeechThreshold",
        "notifyWhenNoPasteTarget",
        "pasteInsteadOfTyping",
        "pauseMediaOnRecord",
        "playSoundOnRecordStart",
        "postRecordHookCommand",
        "postRecordHookEnabled",
        "recordingTriggers",
        "reduceVolumeLevel",
        "reduceVolumeOnRecord",
        "remoteFallbackEnabled",
        "remoteFallbackModelData",
        "remoteServerModel",
        "remoteServerTimeoutEnabled",
        "remoteServerTimeoutSeconds",
        "remoteServerURL",
        "remoteUserPresets",
        "removeFillerWords",
        "retentionMaxAgeEnabled",
        "retentionMaxAgeUnit",
        "retentionMaxAgeValue",
        "retentionMaxCount",
        "retentionMaxCountEnabled",
        "saveTranscriptionHistory",
        "selectedEngine",
        "selectedMicrophoneData",
        "selectedWhisperModelPath",
        "settingsAdvancedRubrics",
        "showCancelButtonOnIndicator",
        "showStopButtonOnIndicator",
        "showTimestamps",
        "startHidden",
        "stopPhrase",
        "stopPhraseSilenceMs",
        "stopPhraseSubmits",
        "submitModifierChord",
        "submitModifierOnlyHotkey",
        "submitMouseButtonHotkey",
        "submitOnVoiceCommand",
        "suppressBlankAudio",
        "temperature",
        "textScale",
        "translateToEnglish",
        "typingPaceMilliseconds",
        "uiTheme",
        "unloadWhisperModelWhenIdle",
        "useAsianAutocorrect",
        "useBeamSearch",
        "useSurroundingTextAsContext",
        "whisperLanguage",
    ]

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    /// Runs one write and asserts it added exactly `key` to the store, which binds each accessor
    /// to its key: two properties swapping keys would fail here even though the set is unchanged.
    private func assertWrites(_ key: String, file: StaticString = #filePath, line: UInt = #line,
                              _ write: () -> Void) {
        let before = Set(scratch.writtenKeys)
        write()
        let added = Set(scratch.writtenKeys).subtracting(before)
        XCTAssertEqual(added, [key], "wrong key written for \(key)", file: file, line: line)
    }

    // MARK: - Keys

    /// The wrappers declared on `AppPreferences`, read by reflection, so a preference added or
    /// renamed without touching the golden list fails even if no test writes it.
    func testDeclaredKeysMatchTheGoldenList() {
        let declared = Mirror(reflecting: prefs).children.compactMap { child -> String? in
            Mirror(reflecting: child.value).children.first { $0.label == "key" }?.value as? String
        }
        XCTAssertEqual(declared.sorted(), Self.goldenKeys)
        XCTAssertEqual(Set(declared).count, declared.count, "two preferences share a key")
    }

    func testEveryPreferenceWritesItsOwnKey() {
        writeEveryPreference()
        XCTAssertEqual(scratch.writtenKeys, Self.goldenKeys)
    }

    private func writeEveryPreference() {
        assertWrites("selectedEngine") { prefs.selectedEngine = "fluidaudio" }
        assertWrites("groqModel") { prefs.groqModel = "groq-model" }
        assertWrites("remoteServerURL") { prefs.remoteServerURL = "http://server" }
        assertWrites("remoteServerModel") { prefs.remoteServerModel = "remote-model" }
        assertWrites("remoteServerTimeoutEnabled") { prefs.remoteServerTimeoutEnabled = false }
        assertWrites("remoteServerTimeoutSeconds") { prefs.remoteServerTimeoutSeconds = 12 }
        assertWrites("cachedRemoteModels") { prefs.cachedRemoteModels = ["a"] }
        assertWrites("appModelRules") { prefs.appModelRulesData = Data([1]) }
        assertWrites("contextAwareModelMode") { prefs.contextAwareModelMode = .off }
        assertWrites("remoteUserPresets") { prefs.remoteUserPresetsData = Data([1]) }
        assertWrites("remoteFallbackEnabled") { prefs.remoteFallbackEnabled = true }
        assertWrites("remoteFallbackModelData") {
            prefs.remoteFallbackModel = DictationModelOption(engine: "whisper", identifier: "/m.bin",
                                                             displayName: "m")
        }
        assertWrites("selectedWhisperModelPath") { prefs.selectedWhisperModelPath = "/m.bin" }
        assertWrites("fluidAudioModelVersion") { prefs.fluidAudioModelVersion = "v2" }
        assertWrites("whisperLanguage") { prefs.whisperLanguage = "fr" }
        assertWrites("translateToEnglish") { prefs.translateToEnglish = true }
        assertWrites("suppressBlankAudio") { prefs.suppressBlankAudio = false }
        assertWrites("showTimestamps") { prefs.showTimestamps = true }
        assertWrites("temperature") { prefs.temperature = 0.4 }
        assertWrites("noSpeechThreshold") { prefs.noSpeechThreshold = 0.3 }
        assertWrites("initialPrompt") { prefs.initialPrompt = "prompt" }
        assertWrites("customDictionaryEnabled") { prefs.customDictionaryEnabled = true }
        assertWrites("customDictionaryBoostEnabled") { prefs.customDictionaryBoostEnabled = true }
        assertWrites("useSurroundingTextAsContext") { prefs.useSurroundingTextAsContext = true }
        assertWrites("customDictionaryData") {
            prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "a", replacement: "b")]
        }
        assertWrites("useBeamSearch") { prefs.useBeamSearch = true }
        assertWrites("showStopButtonOnIndicator") { prefs.showStopButtonOnIndicator = true }
        assertWrites("showCancelButtonOnIndicator") { prefs.showCancelButtonOnIndicator = true }
        assertWrites("beamSize") { prefs.beamSize = 3 }
        assertWrites("debugMode") { prefs.debugMode = true }
        assertWrites("playSoundOnRecordStart") { prefs.playSoundOnRecordStart = true }
        assertWrites("startHidden") { prefs.startHidden = true }
        assertWrites("liveTranscriptionEnabled") { prefs.liveTranscriptionEnabled = true }
        assertWrites("hasCompletedOnboarding") { prefs.hasCompletedOnboarding = true }
        assertWrites("useAsianAutocorrect") { prefs.useAsianAutocorrect = false }
        assertWrites("selectedMicrophoneData") { prefs.selectedMicrophoneData = Data([1]) }
        assertWrites("modifierOnlyHotkey") { prefs.modifierOnlyHotkey = "rightOption" }
        assertWrites("mouseButtonHotkey") { prefs.mouseButtonHotkey = "button4" }
        assertWrites("lastModifierOnlyHotkey") { prefs.lastModifierOnlyHotkey = "fn" }
        assertWrites("lastMouseButtonHotkey") { prefs.lastMouseButtonHotkey = "button5" }
        assertWrites("submitMouseButtonHotkey") { prefs.submitMouseButtonHotkey = "button6" }
        assertWrites("recordingTriggers") { prefs.recordingTriggers = "{}" }
        assertWrites("holdRecordingTriggers") { prefs.holdRecordingTriggers = "{}" }
        assertWrites("submitModifierOnlyHotkey") { prefs.submitModifierOnlyHotkey = "leftShift" }
        assertWrites("submitModifierChord") { prefs.submitModifierChord = "1" }
        assertWrites("escCancelWithoutConfirmation") { prefs.escCancelWithoutConfirmation = true }
        assertWrites("unloadWhisperModelWhenIdle") { prefs.unloadWhisperModelWhenIdle = true }
        assertWrites("holdToRecord") { prefs.holdToRecord = false }
        assertWrites("latchRecordingWithSpace") { prefs.latchRecordingWithSpace = true }
        assertWrites("addSpaceAfterSentence") { prefs.addSpaceAfterSentence = false }
        assertWrites("postRecordHookEnabled") { prefs.postRecordHookEnabled = true }
        assertWrites("postRecordHookCommand") { prefs.postRecordHookCommand = "true" }
        assertWrites("textScale") { prefs.textScale = 1.25 }
        assertWrites("indicatorPosition") { prefs.indicatorPosition = "top" }
        assertWrites("uiTheme") { prefs.uiTheme = "legacy" }
        assertWrites("glassBubbleSize") { prefs.glassBubbleSize = 1 }
        assertWrites("appAppearance") { prefs.appAppearance = "dark" }
        assertWrites("settingsAdvancedRubrics") { prefs.settingsAdvancedRubrics = ["dictation"] }
        assertWrites("indicatorCustomAnchor") { prefs.indicatorCustomAnchor = CGPoint(x: 1, y: 2) }
        assertWrites("indicatorLayout") { prefs.indicatorLayout = "{}" }
        assertWrites("indicatorMeterMode") { prefs.indicatorMeterMode = "off" }
        assertWrites("removeFillerWords") { prefs.removeFillerWords = true }
        assertWrites("fillerWordsPattern") { prefs.fillerWordsPattern = "um" }
        assertWrites("aiPostProcessingEnabled") { prefs.aiPostProcessingEnabled = true }
        assertWrites("aiBackend") { prefs.aiBackend = "remote" }
        assertWrites("aiOllamaEndpoint") { prefs.aiOllamaEndpoint = "http://ollama" }
        assertWrites("aiOllamaModel") { prefs.aiOllamaModel = "ollama-model" }
        assertWrites("aiRemoteEndpoint") { prefs.aiRemoteEndpoint = "http://remote" }
        assertWrites("aiRemoteModel") { prefs.aiRemoteModel = "remote-llm" }
        assertWrites("builtInModelFileName") { prefs.builtInModelFileName = "model.gguf" }
        assertWrites("aiPostProcessingPrompt") { prefs.aiPostProcessingPrompt = "open" }
        assertWrites("aiPostProcessingClosing") { prefs.aiPostProcessingClosing = "close" }
        assertWrites("aiPostProcessingTranslation") { prefs.aiPostProcessingTranslation = "translate" }
        assertWrites("appContextFormattingEnabled") { prefs.appContextFormattingEnabled = true }
        assertWrites("typingPaceMilliseconds") { prefs.typingPaceMilliseconds = 9 }
        assertWrites("appInsertionRulesData") {
            prefs.appInsertionRules = [AppInsertionRule(bundleIdentifier: "com.example", mode: .type)]
        }
        assertWrites("appContextProfilesData") {
            prefs.appContextProfiles = [AppContextProfile(bundleIdentifier: "com.example")]
        }
        assertWrites("didSeedAppContextPresets") { prefs.didSeedAppContextPresets = true }
        assertWrites("autoCopyToClipboard") { prefs.autoCopyToClipboard = false }
        assertWrites("autoPasteTranscription") { prefs.autoPasteTranscription = false }
        assertWrites("clipboardRestoreDelayMs") { prefs.clipboardRestoreDelayMs = 900 }
        assertWrites("pasteInsteadOfTyping") { prefs.pasteInsteadOfTyping = false }
        assertWrites("notifyWhenNoPasteTarget") { prefs.notifyWhenNoPasteTarget = false }
        assertWrites("submitOnVoiceCommand") { prefs.submitOnVoiceCommand = true }
        assertWrites("stopPhrase") { prefs.stopPhrase = "over and out" }
        assertWrites("stopPhraseSubmits") { prefs.stopPhraseSubmits = true }
        assertWrites("stopPhraseSilenceMs") { prefs.stopPhraseSilenceMs = 400 }
        assertWrites("agentAskOnStop") { prefs.agentAskOnStop = false }
        assertWrites("agentAskOnPermission") { prefs.agentAskOnPermission = false }
        assertWrites("agentAskOnQuestion") { prefs.agentAskOnQuestion = false }
        assertWrites("agentWaitSeconds") { prefs.agentWaitSeconds = 60 }
        assertWrites("agentEnabledKinds") { prefs.agentEnabledKinds = ["codex"] }
        assertWrites("agentDisabledProjects") { prefs.agentDisabledProjects = ["/p"] }
        assertWrites("agentRecentProjects") { prefs.agentRecentProjects = ["/p"] }
        assertWrites("pauseMediaOnRecord") { prefs.pauseMediaOnRecord = true }
        assertWrites("reduceVolumeOnRecord") { prefs.reduceVolumeOnRecord = true }
        assertWrites("reduceVolumeLevel") { prefs.reduceVolumeLevel = 0.5 }
        assertWrites("retentionMaxCountEnabled") { prefs.retentionMaxCountEnabled = true }
        assertWrites("retentionMaxCount") { prefs.retentionMaxCount = 10 }
        assertWrites("retentionMaxAgeEnabled") { prefs.retentionMaxAgeEnabled = true }
        assertWrites("retentionMaxAgeValue") { prefs.retentionMaxAgeValue = 2 }
        assertWrites("retentionMaxAgeUnit") { prefs.retentionMaxAgeUnit = "hours" }
        assertWrites("saveTranscriptionHistory") { prefs.saveTranscriptionHistory = false }
    }

    /// `selectedModelPath` is an alias, not a key of its own: it writes the Whisper path while the
    /// Whisper engine is selected and drops the write otherwise.
    func testSelectedModelPathIsAnAliasOfTheWhisperPath() {
        prefs.selectedEngine = "whisper"
        assertWrites("selectedWhisperModelPath") { prefs.selectedModelPath = "/w.bin" }

        prefs.selectedEngine = "fluidaudio"
        prefs.selectedModelPath = "/other.bin"
        XCTAssertNil(prefs.selectedModelPath)
        XCTAssertEqual(prefs.selectedWhisperModelPath, "/w.bin")
    }

    /// The Keychain-backed secrets never touch UserDefaults: a secret that leaked into the
    /// plist would be readable by anything that can read the user's preferences.
    func testSecretsWriteNoDefaultsKey() {
        let secrets = ScratchPreferences(keychainAccounts: ["groqAPIKey", "remoteServerAPIKey", "aiRemoteAPIKey"])
        defer { secrets.restore() }

        prefs.groqAPIKey = "g"
        prefs.remoteServerAPIKey = "r"
        prefs.aiRemoteAPIKey = "a"

        XCTAssertEqual(scratch.writtenKeys, [])
    }

    // MARK: - Stored formats behind the computed accessors

    /// Parsed back from "x,y" on every launch; a different format loses the dragged position.
    func testCustomAnchorIsStoredAsXCommaY() {
        prefs.indicatorCustomAnchor = CGPoint(x: 12.5, y: -3)
        XCTAssertEqual(DefaultsStore.current.string(forKey: "indicatorCustomAnchor"), "12.5,-3.0")
        XCTAssertEqual(prefs.indicatorCustomAnchor, CGPoint(x: 12.5, y: -3))
    }

    /// Writing nil removes the key rather than storing an empty value.
    func testClearingAnOptionalPreferenceRemovesTheKey() {
        prefs.indicatorCustomAnchor = CGPoint(x: 1, y: 1)
        prefs.indicatorCustomAnchor = nil
        prefs.selectedWhisperModelPath = "/m.bin"
        prefs.selectedWhisperModelPath = nil
        XCTAssertEqual(scratch.writtenKeys, [])
    }

    // MARK: - Defaults on a fresh install

    func testFreshStoreReadsTheShippedDefaults() {
        XCTAssertEqual(scratch.writtenKeys, [])

        XCTAssertEqual(prefs.selectedEngine, "whisper")
        XCTAssertEqual(prefs.groqModel, "whisper-large-v3-turbo")
        XCTAssertEqual(prefs.remoteServerURL, "")
        XCTAssertEqual(prefs.remoteServerModel, "")
        XCTAssertEqual(prefs.remoteServerTimeoutEnabled, true)
        XCTAssertEqual(prefs.remoteServerTimeoutSeconds, 60.0)
        XCTAssertEqual(prefs.cachedRemoteModels, [])
        XCTAssertEqual(prefs.appModelRulesData, Data())
        XCTAssertEqual(prefs.contextAwareModelModeRaw, "ask")
        XCTAssertEqual(prefs.contextAwareModelMode, .ask)
        XCTAssertEqual(prefs.remoteUserPresetsData, Data())
        XCTAssertEqual(prefs.remoteFallbackEnabled, false)
        XCTAssertEqual(prefs.remoteFallbackModelData, Data())
        XCTAssertNil(prefs.remoteFallbackModel)
        XCTAssertNil(prefs.selectedWhisperModelPath)
        XCTAssertNil(prefs.selectedModelPath)
        XCTAssertEqual(prefs.fluidAudioModelVersion, "v3")
        XCTAssertEqual(prefs.whisperLanguage, "en")
        XCTAssertEqual(prefs.translateToEnglish, false)
        XCTAssertEqual(prefs.suppressBlankAudio, true)
        XCTAssertEqual(prefs.showTimestamps, false)
        XCTAssertEqual(prefs.temperature, 0.0)
        XCTAssertEqual(prefs.noSpeechThreshold, 0.6)
        XCTAssertEqual(prefs.initialPrompt, "")
        XCTAssertEqual(prefs.customDictionaryEnabled, false)
        XCTAssertEqual(prefs.customDictionaryBoostEnabled, false)
        XCTAssertEqual(prefs.useSurroundingTextAsContext, false)
        XCTAssertEqual(prefs.customDictionaryEntries, [])
        XCTAssertEqual(prefs.useBeamSearch, false)
        XCTAssertEqual(prefs.showStopButtonOnIndicator, false)
        XCTAssertEqual(prefs.showCancelButtonOnIndicator, false)
        XCTAssertEqual(prefs.beamSize, 5)
        XCTAssertEqual(prefs.debugMode, false)
        XCTAssertEqual(prefs.playSoundOnRecordStart, false)
        XCTAssertEqual(prefs.startHidden, false)
        XCTAssertEqual(prefs.liveTranscriptionEnabled, false)
        XCTAssertEqual(prefs.hasCompletedOnboarding, false)
        XCTAssertEqual(prefs.useAsianAutocorrect, true)
        XCTAssertNil(prefs.selectedMicrophoneData)
        XCTAssertEqual(prefs.modifierOnlyHotkey, "none")
        XCTAssertEqual(prefs.mouseButtonHotkey, "none")
        XCTAssertEqual(prefs.lastModifierOnlyHotkey, "leftCommand")
        XCTAssertEqual(prefs.lastMouseButtonHotkey, "middle")
        XCTAssertEqual(prefs.submitMouseButtonHotkey, "none")
        XCTAssertEqual(prefs.recordingTriggers, "")
        XCTAssertEqual(prefs.holdRecordingTriggers, "")
        XCTAssertEqual(prefs.submitModifierOnlyHotkey, "none")
        XCTAssertEqual(prefs.submitModifierChord, "")
        XCTAssertEqual(prefs.escCancelWithoutConfirmation, false)
        XCTAssertEqual(prefs.unloadWhisperModelWhenIdle, false)
        XCTAssertEqual(prefs.holdToRecord, true)
        XCTAssertEqual(prefs.latchRecordingWithSpace, false)
        XCTAssertEqual(prefs.addSpaceAfterSentence, true)
        XCTAssertEqual(prefs.postRecordHookEnabled, false)
        XCTAssertEqual(prefs.postRecordHookCommand, "")
        XCTAssertEqual(prefs.textScale, 1.0)
        XCTAssertEqual(prefs.indicatorPosition, "cursor")
        XCTAssertEqual(prefs.uiTheme, "system")
        XCTAssertEqual(prefs.glassBubbleSize, 0.8)
        XCTAssertEqual(prefs.appAppearance, "system")
        XCTAssertEqual(prefs.settingsAdvancedRubrics, [])
        XCTAssertNil(prefs.indicatorCustomAnchor)
        XCTAssertEqual(prefs.indicatorLayout, "")
        XCTAssertEqual(prefs.indicatorMeterMode, "replacesDot")
        XCTAssertEqual(prefs.removeFillerWords, false)
        XCTAssertEqual(prefs.fillerWordsPattern, "\\b(um|uh|uh huh|er|ah|hmm|mm)\\b,?\\s*")
        XCTAssertEqual(prefs.aiPostProcessingEnabled, false)
        XCTAssertEqual(prefs.aiBackend, "ollama")
        XCTAssertEqual(prefs.aiOllamaEndpoint, "http://localhost:11434")
        XCTAssertEqual(prefs.aiOllamaModel, "llama3.2")
        XCTAssertEqual(prefs.aiRemoteEndpoint, "https://api.groq.com/openai/v1")
        XCTAssertEqual(prefs.aiRemoteModel, "llama-3.1-8b-instant")
        // A file name on disk: a different default would point existing installs at a model
        // they never downloaded.
        XCTAssertEqual(prefs.builtInModelFileName, "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        // Hand-copied literals (see `ShippedCleanupPrompts`), not the LLMPostProcessor constants
        // the defaults are built from.
        XCTAssertEqual(prefs.aiPostProcessingPrompt, ShippedCleanupPrompts.opening)
        XCTAssertEqual(prefs.aiPostProcessingClosing, ShippedCleanupPrompts.closing)
        XCTAssertEqual(prefs.aiPostProcessingTranslation, ShippedCleanupPrompts.translation)
        XCTAssertEqual(prefs.appContextFormattingEnabled, false)
        XCTAssertEqual(prefs.typingPaceMilliseconds, 2)
        XCTAssertEqual(prefs.appInsertionRules, [])
        XCTAssertEqual(prefs.appContextProfiles, [])
        XCTAssertEqual(prefs.didSeedAppContextPresets, false)
        XCTAssertEqual(prefs.autoCopyToClipboard, true)
        XCTAssertEqual(prefs.autoPasteTranscription, true)
        XCTAssertEqual(prefs.clipboardRestoreDelayMs, 500)
        XCTAssertEqual(prefs.pasteInsteadOfTyping, true)
        XCTAssertEqual(prefs.notifyWhenNoPasteTarget, true)
        XCTAssertEqual(prefs.submitOnVoiceCommand, false)
        XCTAssertEqual(prefs.stopPhrase, "")
        XCTAssertEqual(prefs.stopPhraseSubmits, false)
        XCTAssertEqual(prefs.stopPhraseSilenceMs, 1000)
        XCTAssertEqual(prefs.agentAskOnStop, true)
        XCTAssertEqual(prefs.agentAskOnPermission, true)
        XCTAssertEqual(prefs.agentAskOnQuestion, true)
        XCTAssertEqual(prefs.agentWaitSeconds, 300)
        XCTAssertEqual(prefs.agentEnabledKinds, ["claudeCode"])
        XCTAssertEqual(prefs.agentDisabledProjects, [])
        XCTAssertEqual(prefs.agentRecentProjects, [])
        XCTAssertEqual(prefs.pauseMediaOnRecord, false)
        XCTAssertEqual(prefs.reduceVolumeOnRecord, false)
        XCTAssertEqual(prefs.reduceVolumeLevel, 0.1)
        XCTAssertEqual(prefs.retentionMaxCountEnabled, false)
        XCTAssertEqual(prefs.retentionMaxCount, 100)
        XCTAssertEqual(prefs.retentionMaxAgeEnabled, false)
        XCTAssertEqual(prefs.retentionMaxAgeValue, 30)
        XCTAssertEqual(prefs.retentionMaxAgeUnit, "days")
        XCTAssertEqual(prefs.saveTranscriptionHistory, true)

        XCTAssertEqual(scratch.writtenKeys, [], "reading a preference must not write it")
    }

    /// A value of the wrong type under a key reads as the default instead of trapping: the
    /// wrappers cast with `as?`. Pinned because a core protocol could easily force-cast.
    func testAValueOfTheWrongTypeReadsAsTheDefault() {
        DefaultsStore.current.set("not a number", forKey: "beamSize")
        DefaultsStore.current.set(42, forKey: "selectedEngine")
        XCTAssertEqual(prefs.beamSize, 5)
        XCTAssertEqual(prefs.selectedEngine, "whisper")
    }

    // MARK: - Keys written outside AppPreferences

    /// Persisted by other types through the same store; they move or stay with those types, so
    /// their spelling is pinned here with the rest.
    func testKeysWrittenOutsideAppPreferences() {
        assertWrites("appleSpeechLocaleOverrides") { AppleSpeechSupport.localeOverrides = ["fr": "fr_CH"] }

        DefaultsStore.current.set(["xx"], forKey: "appleSpeechSupportedLanguages")
        DefaultsStore.current.set(["yy"], forKey: "appleSpeechInstalledLanguages")
        XCTAssertEqual(AppleSpeechSupport.cachedSupportedLanguages, ["xx"])
        XCTAssertEqual(AppleSpeechSupport.cachedInstalledLanguages, ["yy"])

        LanguageManager.selected = "fr"
        XCTAssertEqual(DefaultsStore.current.string(forKey: "appLanguageOverride"), "fr")
        XCTAssertEqual(DefaultsStore.current.stringArray(forKey: "AppleLanguages"), ["fr"])
        // Removed, not blanked. Read through the suite's own domain: `object(forKey:)` would fall
        // through to the global AppleLanguages.
        LanguageManager.selected = "system"
        XCTAssertFalse(scratch.writtenKeys.contains("AppleLanguages"))
        XCTAssertEqual(DefaultsStore.current.string(forKey: "appLanguageOverride"), "system")
    }
}
