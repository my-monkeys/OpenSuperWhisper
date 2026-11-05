import Foundation
import AVFoundation

protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
}

/// An engine that can be told, in free text, what the speaker was already writing (#89).
///
/// Internal, like `TranscriptionEngine` itself: a public protocol cannot refine an internal one.
/// Nothing outside the module consumes these; `TranscriptionService` dispatches by conformance,
/// so an engine that does not declare one cannot be handed the text at all.
protocol ProseContextEngine: TranscriptionEngine {
    func transcribeAudio(url: URL, settings: TranscriptionSettings,
                         proseContext: String) async throws -> String
}

/// An engine that can be biased toward a list of terms taken from the field (#89).
protocol TermContextEngine: TranscriptionEngine {
    func transcribeAudio(url: URL, settings: TranscriptionSettings,
                         terms: [String]) async throws -> String
}

/// What an engine can do with the text already written in the field being dictated into (#89).
///
/// `none` and `remoteExcluded` are separate because "cannot" and "will not, on purpose" are
/// different things for the UI to say, and because a second hand-maintained list of remote
/// engine ids is a drift hazard.
public enum FieldContextMode: Sendable {
    /// Nowhere to put it.
    case none
    /// Whisper: free text, as an initial prompt.
    case prose
    /// Parakeet: a vocabulary list.
    case terms
    /// An input exists and it must never be used: the text would leave the machine.
    case remoteExcluded

    /// Whether this engine consumes the field.
    ///
    /// An exhaustive switch, deliberately not `self != .none`: `remoteExcluded` is not `.none`,
    /// so that shorthand would mark the one engine that must never see the field as capable and
    /// open its capture gate. A fifth case makes this a compile error rather than a silent
    /// "incapable".
    public var suppliesFieldContext: Bool {
        switch self {
        case .prose, .terms:
            return true
        case .none, .remoteExcluded:
            return false
        }
    }
}

/// Static engine capabilities keyed by the stored engine id (`AppPreferences.selectedEngine`),
/// so the UI can gate features without instantiating an engine.
public enum EngineCapabilities {
    /// Engines that can translate to English — the single source of truth for the
    /// translate toggle's gating AND the local-fallback picker. Add a provider here,
    /// never a new `case` elsewhere. Whisper translates locally; the remote engine
    /// forwards translation to the server's OpenAI `/audio/translations` endpoint.
    /// Parakeet (fluidaudio) / SenseVoice silently ignore `translateToEnglish` (#124).
    public static let translationCapableEngines: Set<String> = ["whisper", "remote"]

    public static func supportsTranslation(engine: String) -> Bool {
        translationCapableEngines.contains(engine)
    }

    /// The one enumerable list of engine ids, for the mode table and the totality test. The
    /// stored ids are a persisted contract, so they stay strings; the test pins this list against
    /// `TranscriptionService.EngineKind` so it cannot drift into a second hand-maintained array.
    public static let allEngineIds: [String] = ["whisper", "fluidaudio", "sensevoice", "remote", "apple"]

    /// What one engine can do with the focused field's text (#89). An id this build does not
    /// know gets `.none`: it is not this table's job to guess, and a wrong `.prose` would read
    /// someone's document for nothing.
    public static func fieldContextMode(for engine: String) -> FieldContextMode {
        switch engine {
        case "whisper":
            return .prose
        case "fluidaudio":
            // `.terms` arrives only in the commit that adds the vocabulary consumer. A capable
            // switch with nothing behind it is the #126 failure.
            return .none
        case "remote":
            // Not for want of a prompt: its prompt is posted to someone else's server, and this
            // text is the user's own writing.
            return .remoteExcluded
        case "sensevoice", "apple":
            return .none
        default:
            return .none
        }
    }

    /// The single gate for the Settings switch and the capture path.
    public static func supportsFieldContext(engine: String) -> Bool {
        fieldContextMode(for: engine).suppliesFieldContext
    }

    /// Whisper can translate, but the turbo models cannot, whatever their documentation says.
    ///
    /// Measured on the same Czech clip: `ggml-small` returns English with `translate` set, while
    /// `ggml-large-v3-turbo-q5_0` returns the Czech unchanged, byte for byte identical to the
    /// untranslated run. Every Whisper model the setup screen offers is a turbo build, so a user
    /// who followed setup had no reachable configuration that could translate, and the toggle
    /// stayed enabled while doing nothing. Reported by a Czech user on 0.10.2.
    public static func supportsTranslation(engine: String, modelPath: String?) -> Bool {
        guard supportsTranslation(engine: engine) else { return false }
        guard engine == "whisper", let modelPath else { return true }
        return !isTurboModel(modelPath)
    }

    static func isTurboModel(_ modelPath: String) -> Bool {
        (modelPath as NSString).lastPathComponent.lowercased().contains("turbo")
    }

    /// The language codes an engine+model can transcribe, in display order. The single source of
    /// truth for both the engines' `getSupportedLanguages()` and the language picker, so the UI can
    /// filter without instantiating an engine and the two can't drift (#155). Whisper uses the full
    /// Whisper set; "auto" (where present) means let the model detect the language.
    public static func supportedLanguages(engine: String, fluidAudioModelVersion: String) -> [String] {
        switch engine {
        case "remote":
            // The remote server decides language support; advertise the full Whisper set
            // (incl. "auto") so the user's choice is forwarded verbatim.
            return LanguageUtil.availableLanguages
        case "apple":
            // System speech model (macOS 26). "auto" = the user's system language — the
            // transcriber has no cross-language auto-detect. The cache is refreshed at
            // launch; before the first refresh, English is the only safe promise.
            let cached = AppleSpeechSupport.cachedSupportedLanguages
            return ["auto"] + (cached.isEmpty ? ["en"] : cached)
        case "sensevoice":
            return ["auto", "zh", "en", "ja", "ko", "yue"]
        case "fluidaudio":
            return fluidAudioModelVersion == "v2"
                ? ["en"]
                : ["en", "de", "es", "fr", "it", "pt", "ru", "pl", "nl", "tr", "cs", "ar", "zh", "ja",
                   "hu", "fi", "hr", "sk", "sr", "sl", "uk", "ca", "da", "el", "bg"]
        default: // whisper — the full Whisper language set
            return LanguageUtil.availableLanguages
        }
    }
}

