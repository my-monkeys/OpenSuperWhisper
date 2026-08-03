import Foundation
import AVFoundation

public protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
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

