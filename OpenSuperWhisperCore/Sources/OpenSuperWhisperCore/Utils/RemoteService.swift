import Foundation

/// The OpenAI-compatible services OSW knows by name, shared by the Remote cleanup and the Remote
/// transcription settings. Any other server is "Custom" (`nil` wherever a service is optional).
/// Model ids, key pages and reasoning parameters were checked against each provider's docs in
/// November 2026 and do drift: when a provider renames one, this is the only place to edit.
public enum RemoteService: String, CaseIterable, Identifiable, Sendable {
    case openRouter, openAI, gemini, groq, mistral

    public var id: String { rawValue }

    public struct TranscriptionModel: Identifiable, Equatable, Sendable {
        public let id: String
        public let description: String
    }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        }
    }

    public var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        }
    }

    /// Substring of the host that identifies the service in a URL the user typed or that was stored.
    private var hostMarker: String {
        switch self {
        case .openRouter: return "openrouter.ai"
        case .openAI: return "api.openai.com"
        case .gemini: return "generativelanguage.googleapis.com"
        case .groq: return "api.groq.com"
        case .mistral: return "api.mistral.ai"
        }
    }

    /// The service a stored server URL points at, so existing configurations open on the right one.
    public static func detect(url: String) -> RemoteService? {
        let lower = url.lowercased()
        return allCases.first { lower.contains($0.hostMarker) }
    }

    /// Where to create an API key.
    public var keyPageURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")!
        }
    }

    /// A fast, cheap chat model that answers right away: the one a cleanup is pre-filled with.
    public var defaultCleanupModel: String {
        switch self {
        case .openRouter: return "google/gemini-2.5-flash-lite"
        case .openAI: return "gpt-4.1-mini"
        case .gemini: return "gemini-3.5-flash-lite"
        case .groq: return "llama-3.1-8b-instant"
        case .mistral: return "mistral-small-2603"
        }
    }

    /// Speech-to-text models of the service's `/audio/transcriptions`, first is the default.
    /// Empty when it has no OpenAI-compatible transcription endpoint (OpenRouter, Gemini), so
    /// the transcription settings do not offer it.
    public var transcriptionModels: [TranscriptionModel] {
        switch self {
        case .openRouter, .gemini:
            return []
        case .openAI:
            return [TranscriptionModel(id: "gpt-transcribe", description: "Recommended by OpenAI"),
                    TranscriptionModel(id: "whisper-1", description: "Supports Translate to English")]
        case .groq:
            return [TranscriptionModel(id: "whisper-large-v3-turbo", description: "Fastest — transcription only"),
                    TranscriptionModel(id: "whisper-large-v3", description: "Supports Translate to English")]
        case .mistral:
            return [TranscriptionModel(id: "voxtral-mini-latest", description: "Voxtral Mini")]
        }
    }

    public static var transcriptionServices: [RemoteService] { allCases.filter { !$0.transcriptionModels.isEmpty } }

    public var defaultTranscriptionModel: String? { transcriptionModels.first?.id }

    /// The model that also translates to English, when the service has one.
    public var translatingModel: String? {
        switch self {
        case .groq: return "whisper-large-v3"
        case .openAI: return "whisper-1"
        default: return nil
        }
    }

    // MARK: Key prefix

    /// True when the key plainly belongs to another service. Only a warning: keys change shape,
    /// and a proxy may well be fed a key of another family. Empty keys and Mistral (whose keys
    /// have no fixed prefix) never mismatch.
    public func keyLooksForeign(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        switch self {
        case .groq: return !key.hasPrefix("gsk_")
        case .openRouter: return !key.hasPrefix("sk-or-")
        case .openAI: return !key.hasPrefix("sk-") || key.hasPrefix("sk-or-")
        case .gemini: return !key.hasPrefix("AIza")
        case .mistral: return false
        }
    }

    /// The prefix to show in the warning, nil when the service has none.
    public var keyPrefixHint: String? {
        switch self {
        case .groq: return "gsk_"
        case .openRouter: return "sk-or-"
        case .openAI: return "sk-"
        case .gemini: return "AIza"
        case .mistral: return nil
        }
    }

    // MARK: Reasoning

    /// Whether cleanup requests switch reasoning off: the user's choice when there is one, else
    /// on for a known service and off for Custom, which must never receive a field it may not know.
    public static func disablesReasoning(stored: Bool?, service: RemoteService?) -> Bool {
        stored ?? (service != nil)
    }

    /// The chat-request fields that turn reasoning off (or to its minimum) for `model`. Each
    /// service has its own spelling, and several accept it only on some models: a model the
    /// provider documents no switch for gets nothing rather than a field it may refuse with a 400.
    /// A Custom server gets OpenAI's `reasoning_effort`, because the user asked for it.
    public static func reasoningFields(service: RemoteService?, model: String) -> [String: Any] {
        let id = model.trimmingCharacters(in: .whitespaces).lowercased()
        switch service {
        case nil:
            return ["reasoning_effort": "none"]
        case .openRouter:
            // `none` is refused (400) by models OpenRouter registers with mandatory reasoning.
            return ["reasoning": ["effort": "none"], "provider": ["sort": "latency"]]
        case .openAI:
            // The 4.x chat models do not reason and refuse the field.
            return id.hasPrefix("gpt-5.") || id.hasPrefix("gpt-6") ? ["reasoning_effort": "none"] : [:]
        case .gemini:
            if id.contains("pro") { return [:] }   // cannot be turned off
            if id.hasPrefix("gemini-2.5") { return ["reasoning_effort": "none"] }
            return id.hasPrefix("gemini-3") ? ["reasoning_effort": "minimal"] : [:]
        case .groq:
            if id.contains("qwen") { return ["reasoning_effort": "none"] }
            return id.contains("gpt-oss") ? ["reasoning_effort": "low"] : [:]
        case .mistral:
            let adjustable = id.hasPrefix("mistral-small-2603") || id.hasPrefix("mistral-medium-3-5")
            return adjustable ? ["reasoning_effort": "none"] : [:]
        }
    }
}
