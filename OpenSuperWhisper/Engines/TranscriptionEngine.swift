import Foundation
import AVFoundation

protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
}

/// Static engine capabilities keyed by the stored engine id (`AppPreferences.selectedEngine`),
/// so the UI can gate features without instantiating an engine.
enum EngineCapabilities {
    /// Engines that can translate to English — the single source of truth for the
    /// translate toggle's gating AND the local-fallback picker. Add a provider here,
    /// never a new `case` elsewhere. Whisper translates locally; the remote engine
    /// forwards translation to the server's OpenAI `/audio/translations` endpoint.
    /// Parakeet (fluidaudio) / SenseVoice silently ignore `translateToEnglish` (#124).
    static let translationCapableEngines: Set<String> = ["whisper", "remote"]

    static func supportsTranslation(engine: String) -> Bool {
        translationCapableEngines.contains(engine)
    }

    /// Engines that can be told, in free text, what the speaker is about to say. Whisper
    /// conditions on an initial prompt; Parakeet takes a vocabulary list, Apple takes
    /// contextual strings and SenseVoice takes nothing, so the contents of the field have
    /// nowhere to go there. The remote engine is left out deliberately rather than for lack of
    /// a prompt: its prompt is posted to someone else's server, and this text is the user's own
    /// writing (#89).
    static let fieldContextCapableEngines: Set<String> = ["whisper"]

    static func supportsFieldContext(engine: String) -> Bool {
        fieldContextCapableEngines.contains(engine)
    }

    /// Whisper can translate, but the turbo models cannot, whatever their documentation says.
    ///
    /// Measured on the same Czech clip: `ggml-small` returns English with `translate` set, while
    /// `ggml-large-v3-turbo-q5_0` returns the Czech unchanged, byte for byte identical to the
    /// untranslated run. Every Whisper model the setup screen offers is a turbo build, so a user
    /// who followed setup had no reachable configuration that could translate, and the toggle
    /// stayed enabled while doing nothing. Reported by a Czech user on 0.10.2.
    static func supportsTranslation(engine: String, modelPath: String?) -> Bool {
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
    static func supportedLanguages(engine: String, fluidAudioModelVersion: String) -> [String] {
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

