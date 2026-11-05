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
    /// The snippet triggers to bias recognition toward, already gated by the host's snippet
    /// switches. Set per clip, and only for a dictation: snippets are expanded by the host after
    /// the cleanup model, and nothing expands them in a dropped file or a CLI run.
    public var snippetTriggers: [String]

    /// There is deliberately no field-text member here. This value is handed to every engine,
    /// including the remote one, so a field on it would make the remote exclusion a convention —
    /// a consumer choosing not to read it. The captured text travels as an argument to
    /// `TranscriptionService` instead, and only reaches an engine that conforms to a context
    /// protocol (#89).
    public init(selectedLanguage: String, translateToEnglish: Bool, suppressBlankAudio: Bool,
                showTimestamps: Bool, temperature: Double, noSpeechThreshold: Double,
                initialPrompt: String, useBeamSearch: Bool, beamSize: Int, useAsianAutocorrect: Bool,
                customDictionaryEnabled: Bool, customDictionaryBoostEnabled: Bool,
                customDictionaryEntries: [CustomDictionaryEntry], useSurroundingTextAsContext: Bool,
                snippetTriggers: [String] = []) {
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
        self.snippetTriggers = snippetTriggers
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

    /// Everything this clip's recognition leans toward: the dictionary's terms when their boost
    /// is on, then the snippet triggers.
    public var recognitionBoostTerms: [String] {
        RecognitionBoost.terms(
            dictionary: shouldBoostCustomDictionary
                ? CustomDictionary.boostTerms(entries: customDictionaryEntries) : [],
            snippets: snippetTriggers)
    }
}
