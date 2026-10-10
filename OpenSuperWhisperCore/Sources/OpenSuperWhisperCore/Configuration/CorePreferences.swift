import Foundation

/// Every preference the core reads or writes, with the keys and storage of the host. The macOS
/// app's `AppPreferences` conforms as it is. Class-bound so the setters work through the
/// existential, and not actor-isolated because engines read it from detached tasks and from the
/// llama inference queue.
public protocol CorePreferences: AnyObject, Sendable {
    // Engine and model selection
    var selectedEngine: String { get set }
    var selectedWhisperModelPath: String? { get set }
    var selectedModelPath: String? { get }
    var fluidAudioModelVersion: String { get set }
    var unloadWhisperModelWhenIdle: Bool { get }

    // Custom dictionary
    var customDictionaryEnabled: Bool { get }
    var customDictionaryBoostEnabled: Bool { get }
    var customDictionaryEntries: [CustomDictionaryEntry] { get }

    // Remote server
    var remoteServerURL: String { get }
    var remoteServerModel: String { get set }
    var remoteServerAPIKey: String? { get }
    var remoteServerTimeoutEnabled: Bool { get }
    var remoteServerTimeoutSeconds: Double { get }
    var cachedRemoteModels: [String] { get }
    var remoteFallbackEnabled: Bool { get }
    var remoteFallbackModel: DictationModelOption? { get }

    // History and retention
    var saveTranscriptionHistory: Bool { get set }
    var retentionMaxCountEnabled: Bool { get }
    var retentionMaxCount: Int { get }
    var retentionMaxAgeEnabled: Bool { get }
    var retentionMaxAgeValue: Int { get }
    var retentionMaxAgeUnit: String { get }

    // LLM cleanup
    var aiBackend: String { get }
    var aiRemoteEndpoint: String { get }
    var aiRemoteModel: String { get }
    var aiRemoteAPIKey: String? { get }
    var aiOllamaEndpoint: String { get }
    var aiOllamaModel: String { get }
    var aiPostProcessingEnabled: Bool { get }
    var appContextFormattingEnabled: Bool { get }
    var appContextProfiles: [AppContextProfile] { get }
    var aiPostProcessingPrompt: String { get }
    var aiPostProcessingClosing: String { get }
    var aiPostProcessingTranslation: String { get }
    var builtInModelFileName: String { get }
}
