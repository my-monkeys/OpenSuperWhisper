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
    public var customDictionaryEntries: [CustomDictionaryEntry]
    public var useSurroundingTextAsContext: Bool
    /// The snippet triggers to bias recognition toward, already gated by the host's snippet
    /// switches. Set per clip, and only for a dictation: snippets are expanded by the host after
    /// the cleanup model, and nothing expands them in a dropped file or a CLI run.
    public var snippetTriggers: [String]
    /// The field's contents at record-start, set per clip by the pipeline rather than read from
    /// preferences: it belongs to one dictation, not to the app's standing configuration.
    public var focusedText: String?

    public init(selectedLanguage: String, translateToEnglish: Bool, suppressBlankAudio: Bool,
                showTimestamps: Bool, temperature: Double, noSpeechThreshold: Double,
                initialPrompt: String, useBeamSearch: Bool, beamSize: Int, useAsianAutocorrect: Bool,
                customDictionaryEnabled: Bool,
                customDictionaryEntries: [CustomDictionaryEntry], useSurroundingTextAsContext: Bool,
                snippetTriggers: [String] = [], focusedText: String? = nil) {
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
        self.customDictionaryEntries = customDictionaryEntries
        self.useSurroundingTextAsContext = useSurroundingTextAsContext
        self.snippetTriggers = snippetTriggers
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

    /// Everything this clip's recognition leans toward: the terms of the dictionary entries that
    /// steer recognition, then the snippet triggers.
    public var recognitionBoostTerms: [String] {
        RecognitionBoost.terms(
            dictionary: shouldApplyCustomDictionary
                ? CustomDictionary.boostTerms(entries: customDictionaryEntries) : [],
            snippets: snippetTriggers)
    }
}
