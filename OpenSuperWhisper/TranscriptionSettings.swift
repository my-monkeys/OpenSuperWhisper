struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    var customDictionaryEnabled: Bool
    var customDictionaryBoostEnabled: Bool
    var customDictionaryEntries: [CustomDictionaryEntry]

    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }

    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    var shouldApplyCustomDictionary: Bool {
        customDictionaryEnabled && !customDictionaryEntries.isEmpty
    }

    /// Whether to also bias recognition toward the dictionary terms (opt-in, on top of the
    /// always-on text replacement). Gated by the separate `customDictionaryBoostEnabled` flag.
    var shouldBoostCustomDictionary: Bool {
        customDictionaryBoostEnabled && shouldApplyCustomDictionary
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.customDictionaryEnabled = prefs.customDictionaryEnabled
        self.customDictionaryBoostEnabled = prefs.customDictionaryBoostEnabled
        self.customDictionaryEntries = prefs.customDictionaryEntries
    }
}
