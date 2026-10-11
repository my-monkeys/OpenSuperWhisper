import Foundation
import os
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

    // Core code reads preferences from detached tasks and from llama's inference queue, while
    // `CoreTestCase.tearDown` resets them on the main thread.
    private let state = OSAllocatedUnfairLock(initialState: Values())

    private subscript<Value: Sendable>(key: WritableKeyPath<Values, Value>) -> Value {
        get { state.withLock { $0[keyPath: key] } }
        set { state.withLock { $0[keyPath: key] = newValue } }
    }

    func reset() { state.withLock { $0 = Values() } }

    var selectedEngine: String {
        get { self[\.selectedEngine] }
        set { self[\.selectedEngine] = newValue }
    }
    var selectedWhisperModelPath: String? {
        get { self[\.selectedWhisperModelPath] }
        set { self[\.selectedWhisperModelPath] = newValue }
    }
    var selectedModelPath: String? {
        state.withLock { $0.selectedEngine == "whisper" ? $0.selectedWhisperModelPath : nil }
    }
    var fluidAudioModelVersion: String {
        get { self[\.fluidAudioModelVersion] }
        set { self[\.fluidAudioModelVersion] = newValue }
    }
    var unloadWhisperModelWhenIdle: Bool {
        get { self[\.unloadWhisperModelWhenIdle] }
        set { self[\.unloadWhisperModelWhenIdle] = newValue }
    }

    var customDictionaryEnabled: Bool {
        get { self[\.customDictionaryEnabled] }
        set { self[\.customDictionaryEnabled] = newValue }
    }
    var customDictionaryBoostEnabled: Bool {
        get { self[\.customDictionaryBoostEnabled] }
        set { self[\.customDictionaryBoostEnabled] = newValue }
    }
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get { self[\.customDictionaryEntries] }
        set { self[\.customDictionaryEntries] = newValue }
    }

    var remoteServerURL: String {
        get { self[\.remoteServerURL] }
        set { self[\.remoteServerURL] = newValue }
    }
    var remoteServerModel: String {
        get { self[\.remoteServerModel] }
        set { self[\.remoteServerModel] = newValue }
    }
    var remoteServerAPIKey: String? {
        get { self[\.remoteServerAPIKey] }
        set { self[\.remoteServerAPIKey] = newValue }
    }
    var remoteServerTimeoutEnabled: Bool {
        get { self[\.remoteServerTimeoutEnabled] }
        set { self[\.remoteServerTimeoutEnabled] = newValue }
    }
    var remoteServerTimeoutSeconds: Double {
        get { self[\.remoteServerTimeoutSeconds] }
        set { self[\.remoteServerTimeoutSeconds] = newValue }
    }
    var cachedRemoteModels: [String] {
        get { self[\.cachedRemoteModels] }
        set { self[\.cachedRemoteModels] = newValue }
    }
    var remoteFallbackEnabled: Bool {
        get { self[\.remoteFallbackEnabled] }
        set { self[\.remoteFallbackEnabled] = newValue }
    }
    var remoteFallbackModel: DictationModelOption? {
        get { self[\.remoteFallbackModel] }
        set { self[\.remoteFallbackModel] = newValue }
    }

    var saveTranscriptionHistory: Bool {
        get { self[\.saveTranscriptionHistory] }
        set { self[\.saveTranscriptionHistory] = newValue }
    }
    var retentionMaxCountEnabled: Bool {
        get { self[\.retentionMaxCountEnabled] }
        set { self[\.retentionMaxCountEnabled] = newValue }
    }
    var retentionMaxCount: Int {
        get { self[\.retentionMaxCount] }
        set { self[\.retentionMaxCount] = newValue }
    }
    var retentionMaxAgeEnabled: Bool {
        get { self[\.retentionMaxAgeEnabled] }
        set { self[\.retentionMaxAgeEnabled] = newValue }
    }
    var retentionMaxAgeValue: Int {
        get { self[\.retentionMaxAgeValue] }
        set { self[\.retentionMaxAgeValue] = newValue }
    }
    var retentionMaxAgeUnit: String {
        get { self[\.retentionMaxAgeUnit] }
        set { self[\.retentionMaxAgeUnit] = newValue }
    }

    var aiBackend: String {
        get { self[\.aiBackend] }
        set { self[\.aiBackend] = newValue }
    }
    var aiRemoteEndpoint: String {
        get { self[\.aiRemoteEndpoint] }
        set { self[\.aiRemoteEndpoint] = newValue }
    }
    var aiRemoteModel: String {
        get { self[\.aiRemoteModel] }
        set { self[\.aiRemoteModel] = newValue }
    }
    var aiRemoteAPIKey: String? {
        get { self[\.aiRemoteAPIKey] }
        set { self[\.aiRemoteAPIKey] = newValue }
    }
    var aiOllamaEndpoint: String {
        get { self[\.aiOllamaEndpoint] }
        set { self[\.aiOllamaEndpoint] = newValue }
    }
    var aiOllamaModel: String {
        get { self[\.aiOllamaModel] }
        set { self[\.aiOllamaModel] = newValue }
    }
    var aiPostProcessingEnabled: Bool {
        get { self[\.aiPostProcessingEnabled] }
        set { self[\.aiPostProcessingEnabled] = newValue }
    }
    var appContextFormattingEnabled: Bool {
        get { self[\.appContextFormattingEnabled] }
        set { self[\.appContextFormattingEnabled] = newValue }
    }
    var appContextProfiles: [AppContextProfile] {
        get { self[\.appContextProfiles] }
        set { self[\.appContextProfiles] = newValue }
    }
    var aiPostProcessingPrompt: String {
        get { self[\.aiPostProcessingPrompt] }
        set { self[\.aiPostProcessingPrompt] = newValue }
    }
    var aiPostProcessingClosing: String {
        get { self[\.aiPostProcessingClosing] }
        set { self[\.aiPostProcessingClosing] = newValue }
    }
    var aiPostProcessingTranslation: String {
        get { self[\.aiPostProcessingTranslation] }
        set { self[\.aiPostProcessingTranslation] = newValue }
    }
    var builtInModelFileName: String {
        get { self[\.builtInModelFileName] }
        set { self[\.builtInModelFileName] = newValue }
    }
}
