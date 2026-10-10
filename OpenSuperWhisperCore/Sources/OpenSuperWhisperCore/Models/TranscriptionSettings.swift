import Foundation

/// How one clip is transcribed: language, decoding options, prompt and dictionary. The macOS app
/// builds it from its preferences (`Settings()` there); a host without them uses the memberwise
/// initialiser.
public struct TranscriptionSettings: Sendable {
    public static let asianLanguages: Set<String> = ["zh", "ja", "ko"]

    public var selectedLanguage: String
    public var translateToEnglish: Bool
    public var suppressBlankAudio: Bool
    public var showTimestamps: Bool
    public var temperature: Double
    public var noSpeechThreshold: Double
    public var initialPrompt: String
    public var useBeamSearch: Bool
    public var beamSize: Int
    public var useAsianAutocorrect: Bool
    public var customDictionaryEnabled: Bool
    public var customDictionaryBoostEnabled: Bool
    public var customDictionaryEntries: [CustomDictionaryEntry]
    public var useSurroundingTextAsContext: Bool
    /// The field's contents at record-start, set per clip by the pipeline rather than read from
    /// preferences: it belongs to one dictation, not to the app's standing configuration.
    public var focusedText: String?

    public init(selectedLanguage: String, translateToEnglish: Bool, suppressBlankAudio: Bool,
                showTimestamps: Bool, temperature: Double, noSpeechThreshold: Double,
                initialPrompt: String, useBeamSearch: Bool, beamSize: Int, useAsianAutocorrect: Bool,
                customDictionaryEnabled: Bool, customDictionaryBoostEnabled: Bool,
                customDictionaryEntries: [CustomDictionaryEntry], useSurroundingTextAsContext: Bool,
                focusedText: String? = nil) {
        self.selectedLanguage = selectedLanguage
        self.translateToEnglish = translateToEnglish
        self.suppressBlankAudio = suppressBlankAudio
        self.showTimestamps = showTimestamps
        self.temperature = temperature
        self.noSpeechThreshold = noSpeechThreshold
        self.initialPrompt = initialPrompt
        self.useBeamSearch = useBeamSearch
        self.beamSize = beamSize
        self.useAsianAutocorrect = useAsianAutocorrect
        self.customDictionaryEnabled = customDictionaryEnabled
        self.customDictionaryBoostEnabled = customDictionaryBoostEnabled
        self.customDictionaryEntries = customDictionaryEntries
        self.useSurroundingTextAsContext = useSurroundingTextAsContext
        self.focusedText = focusedText
    }

    public var isAsianLanguage: Bool {
        TranscriptionSettings.asianLanguages.contains(selectedLanguage)
    }

    public var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    public var shouldApplyCustomDictionary: Bool {
        customDictionaryEnabled && !customDictionaryEntries.isEmpty
    }

    /// Whether to also bias recognition toward the dictionary terms (opt-in, on top of the
    /// always-on text replacement). Gated by the separate `customDictionaryBoostEnabled` flag.
    public var shouldBoostCustomDictionary: Bool {
        customDictionaryBoostEnabled && shouldApplyCustomDictionary
    }
}
