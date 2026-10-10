import Foundation
@testable import OpenSuperWhisperCore

/// In-memory preferences for the core tests. Touches no UserDefaults and no Keychain: the two
/// Keychain-backed members of the app are plain stored values here, so no core code path reaches
/// the Keychain through the preferences.
///
/// Starts from the app's fresh-install values for the members the core branches on, and nil,
/// false or empty for the rest. No test may rely on these matching the app: the hosted
/// `DefaultsKeySnapshotTests` pins the app's defaults.
final class TestPreferences: CorePreferences, @unchecked Sendable {
    private struct Values {
        var selectedEngine = "whisper"
        var selectedWhisperModelPath: String?
        var fluidAudioModelVersion = "v3"
        var unloadWhisperModelWhenIdle = false

        var customDictionaryEnabled = false
        var customDictionaryBoostEnabled = false
        var customDictionaryEntries: [CustomDictionaryEntry] = []

        var remoteServerURL = ""
        var remoteServerModel = ""
        var remoteServerAPIKey: String?
        var remoteServerTimeoutEnabled = true
        var remoteServerTimeoutSeconds: Double = 60
        var cachedRemoteModels: [String] = []
        var remoteFallbackEnabled = false
        var remoteFallbackModel: DictationModelOption?

        var saveTranscriptionHistory = true
        var retentionMaxCountEnabled = false
        var retentionMaxCount = 100
        var retentionMaxAgeEnabled = false
        var retentionMaxAgeValue = 30
        var retentionMaxAgeUnit = "days"

        var aiBackend = "ollama"
        var aiRemoteEndpoint = ""
        var aiRemoteModel = ""
        var aiRemoteAPIKey: String?
        var aiOllamaEndpoint = ""
        var aiOllamaModel = ""
        var aiPostProcessingEnabled = false
        var appContextFormattingEnabled = false
        var appContextProfiles: [AppContextProfile] = []
        var aiPostProcessingPrompt = LLMPostProcessor.defaultInstruction
        var aiPostProcessingClosing = LLMPostProcessor.defaultClosingInstruction
        var aiPostProcessingTranslation = LLMPostProcessor.defaultTranslationInstruction
        var builtInModelFileName = LLMModelManager.defaultModel.fileName
    }

    private var values = Values()

    func reset() { values = Values() }

    var selectedEngine: String { get { values.selectedEngine } set { values.selectedEngine = newValue } }
    var selectedWhisperModelPath: String? {
        get { values.selectedWhisperModelPath }
        set { values.selectedWhisperModelPath = newValue }
    }
    var selectedModelPath: String? {
        values.selectedEngine == "whisper" ? values.selectedWhisperModelPath : nil
    }
    var fluidAudioModelVersion: String {
        get { values.fluidAudioModelVersion }
        set { values.fluidAudioModelVersion = newValue }
    }
    var unloadWhisperModelWhenIdle: Bool {
        get { values.unloadWhisperModelWhenIdle }
        set { values.unloadWhisperModelWhenIdle = newValue }
    }

    var customDictionaryEnabled: Bool {
        get { values.customDictionaryEnabled }
        set { values.customDictionaryEnabled = newValue }
    }
    var customDictionaryBoostEnabled: Bool {
        get { values.customDictionaryBoostEnabled }
        set { values.customDictionaryBoostEnabled = newValue }
    }
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get { values.customDictionaryEntries }
        set { values.customDictionaryEntries = newValue }
    }

    var remoteServerURL: String { get { values.remoteServerURL } set { values.remoteServerURL = newValue } }
    var remoteServerModel: String { get { values.remoteServerModel } set { values.remoteServerModel = newValue } }
    var remoteServerAPIKey: String? {
        get { values.remoteServerAPIKey }
        set { values.remoteServerAPIKey = newValue }
    }
    var remoteServerTimeoutEnabled: Bool {
        get { values.remoteServerTimeoutEnabled }
        set { values.remoteServerTimeoutEnabled = newValue }
    }
    var remoteServerTimeoutSeconds: Double {
        get { values.remoteServerTimeoutSeconds }
        set { values.remoteServerTimeoutSeconds = newValue }
    }
    var cachedRemoteModels: [String] {
        get { values.cachedRemoteModels }
        set { values.cachedRemoteModels = newValue }
    }
    var remoteFallbackEnabled: Bool {
        get { values.remoteFallbackEnabled }
        set { values.remoteFallbackEnabled = newValue }
    }
    var remoteFallbackModel: DictationModelOption? {
        get { values.remoteFallbackModel }
        set { values.remoteFallbackModel = newValue }
    }

    var saveTranscriptionHistory: Bool {
        get { values.saveTranscriptionHistory }
        set { values.saveTranscriptionHistory = newValue }
    }
    var retentionMaxCountEnabled: Bool {
        get { values.retentionMaxCountEnabled }
        set { values.retentionMaxCountEnabled = newValue }
    }
    var retentionMaxCount: Int { get { values.retentionMaxCount } set { values.retentionMaxCount = newValue } }
    var retentionMaxAgeEnabled: Bool {
        get { values.retentionMaxAgeEnabled }
        set { values.retentionMaxAgeEnabled = newValue }
    }
    var retentionMaxAgeValue: Int {
        get { values.retentionMaxAgeValue }
        set { values.retentionMaxAgeValue = newValue }
    }
    var retentionMaxAgeUnit: String {
        get { values.retentionMaxAgeUnit }
        set { values.retentionMaxAgeUnit = newValue }
    }

    var aiBackend: String { get { values.aiBackend } set { values.aiBackend = newValue } }
    var aiRemoteEndpoint: String { get { values.aiRemoteEndpoint } set { values.aiRemoteEndpoint = newValue } }
    var aiRemoteModel: String { get { values.aiRemoteModel } set { values.aiRemoteModel = newValue } }
    var aiRemoteAPIKey: String? { get { values.aiRemoteAPIKey } set { values.aiRemoteAPIKey = newValue } }
    var aiOllamaEndpoint: String { get { values.aiOllamaEndpoint } set { values.aiOllamaEndpoint = newValue } }
    var aiOllamaModel: String { get { values.aiOllamaModel } set { values.aiOllamaModel = newValue } }
    var aiPostProcessingEnabled: Bool {
        get { values.aiPostProcessingEnabled }
        set { values.aiPostProcessingEnabled = newValue }
    }
    var appContextFormattingEnabled: Bool {
        get { values.appContextFormattingEnabled }
        set { values.appContextFormattingEnabled = newValue }
    }
    var appContextProfiles: [AppContextProfile] {
        get { values.appContextProfiles }
        set { values.appContextProfiles = newValue }
    }
    var aiPostProcessingPrompt: String {
        get { values.aiPostProcessingPrompt }
        set { values.aiPostProcessingPrompt = newValue }
    }
    var aiPostProcessingClosing: String {
        get { values.aiPostProcessingClosing }
        set { values.aiPostProcessingClosing = newValue }
    }
    var aiPostProcessingTranslation: String {
        get { values.aiPostProcessingTranslation }
        set { values.aiPostProcessingTranslation = newValue }
    }
    var builtInModelFileName: String {
        get { values.builtInModelFileName }
        set { values.builtInModelFileName = newValue }
    }
}
