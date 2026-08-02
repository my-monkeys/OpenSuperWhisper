import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    /// True while re-syncing the @Published copies from AppPreferences (e.g. after the
    /// menu-bar Model picker changed the active model). Suppresses the model didSets'
    /// side effects so the sync doesn't write back, double-reload, or clobber the engine.
    private var isSyncing = false
    private var modelSyncObserver: NSObjectProtocol?
    private var languageSyncObserver: NSObjectProtocol?
    private var translateSyncObserver: NSObjectProtocol?

    @Published var selectedEngine: String {
        didSet {
            guard !isSyncing else { return }
            // The active selection is owned by ModelSelectionStore (see the select* methods,
            // which persist + reload the engine). This observer only refreshes the model list
            // shown for whatever engine is now displayed.
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else {
                initializeFluidAudioModels()
            }
            clampLanguageToSupported()
        }
    }
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            guard !isSyncing else { return }
            // Selection (engine switch + persistence + reload) is applied via selectParakeet(_:);
            // this observer only refreshes the row download states.
            initializeFluidAudioModels()
        }
    }
    
    @Published var selectedModelURL: URL? {
        didSet {
            guard !isSyncing else { return }
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    // MARK: - Remote (OpenAI-compatible) engine settings

    @Published var remoteServerURL: String {
        didSet {
            AppPreferences.shared.remoteServerURL = remoteServerURL
            reloadRemoteEngineIfSelected()
        }
    }

    @Published var remoteServerModel: String {
        didSet {
            guard !isSyncing else { return }
            AppPreferences.shared.remoteServerModel = remoteServerModel
            reloadRemoteEngineIfSelected()
            // Editing the model string while Remote is the active engine changes the active
            // selection — keep the store's mirror current (selectRemote covers the click path).
            if selectedEngine == "remote" {
                MainActor.assumeIsolated { ModelSelectionStore.shared.refresh() }
            }
        }
    }

    /// Non-optional in the UI (empty == "no key"); persisted to the Keychain-backed
    /// optional `AppPreferences.remoteServerAPIKey` (empty clears it).
    @Published var remoteServerAPIKey: String {
        didSet {
            AppPreferences.shared.remoteServerAPIKey = remoteServerAPIKey
            reloadRemoteEngineIfSelected()
        }
    }

    @Published var remoteServerTimeoutEnabled: Bool {
        didSet {
            AppPreferences.shared.remoteServerTimeoutEnabled = remoteServerTimeoutEnabled
            reloadRemoteEngineIfSelected()
        }
    }

    @Published var remoteServerTimeoutSeconds: Double {
        didSet {
            AppPreferences.shared.remoteServerTimeoutSeconds = remoteServerTimeoutSeconds
            reloadRemoteEngineIfSelected()
        }
    }

    /// Context-aware model selection mode (per-app / per-site rules). See F2.
    @Published var contextAwareModelMode: ContextAwareModelMode {
        didSet {
            AppPreferences.shared.contextAwareModelMode = contextAwareModelMode
        }
    }

    /// Re-initialize the engine on a remote-config change, but only when the remote
    /// engine is the active one (editing the config while on Whisper shouldn't reload).
    private func reloadRemoteEngineIfSelected() {
        guard selectedEngine == "remote" else { return }
        Task { @MainActor in
            TranscriptionService.shared.reloadEngine()
        }
    }

    /// User-initiated model selections. Each routes through the single mutation point —
    /// `ModelSelectionStore.select` — so the menu bar, Settings, and the context rules all change
    /// the active model the same way and can't drift. The store persists to AppPreferences,
    /// reloads the engine, and posts `.modelSelectionDidChange`, which syncs our @Published copies
    /// back (`syncModelSelectionFromPreferences`). Call these for explicit user actions only —
    /// never from init/restore — so a routine reload can't override the language.
    func selectModel(_ url: URL) {
        MainActor.assumeIsolated {
            ModelSelectionStore.shared.select(DictationModelOption(
                engine: "whisper",
                identifier: url.path,
                displayName: url.deletingPathExtension().lastPathComponent))
        }
        // A model may declare a preferred language (e.g. the ivrit.ai Hebrew model) — switch to it.
        if let lang = SettingsDownloadableModels.preferredLanguage(forFilename: url.lastPathComponent),
           selectedLanguage != lang {
            selectedLanguage = lang
        }
    }

    func selectParakeet(_ version: String) {
        MainActor.assumeIsolated {
            ModelSelectionStore.shared.select(DictationModelOption(
                engine: "fluidaudio", identifier: version, displayName: version))
        }
    }

    func selectRemote(_ id: String) {
        MainActor.assumeIsolated {
            ModelSelectionStore.shared.select(DictationModelOption(
                engine: "remote", identifier: id, displayName: id))
        }
    }

    func selectSenseVoice() {
        MainActor.assumeIsolated {
            ModelSelectionStore.shared.select(DictationModelOption(
                engine: "sensevoice", identifier: "default", displayName: "SenseVoice"))
        }
    }

    func selectAppleSpeech() {
        MainActor.assumeIsolated {
            ModelSelectionStore.shared.select(DictationModelOption(
                engine: "apple", identifier: "default", displayName: "Apple Speech"))
        }
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    
    @Published var selectedLanguage: String {
        didSet {
            // Single mutation point (LanguageStore) — persists + notifies the menu. Idempotent,
            // so the menu→Settings sync setting this back to the same value is a harmless no-op.
            MainActor.assumeIsolated { LanguageStore.shared.select(selectedLanguage) }
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            MainActor.assumeIsolated { TranslateStore.shared.set(translateToEnglish) }
        }
    }

    /// Whether the selected engine can translate to English (#124). When false the
    /// "Translate to English" toggle is disabled — Parakeet/SenseVoice ignore the flag, so
    /// showing an active toggle is misleading.
    var canTranslate: Bool {
        EngineCapabilities.supportsTranslation(engine: selectedEngine)
    }

    /// Languages the selected engine+model can transcribe — filters the language picker (#155).
    var supportedLanguages: [String] {
        EngineCapabilities.supportedLanguages(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
    }

    /// Reset the language to a supported one when the current engine/model can't transcribe the
    /// previously selected one (e.g. switching to a model without that language) (#155). Prefers
    /// Auto-detect, then English, then whatever the model lists first — so the picker is never blank.
    func clampLanguageToSupported() {
        let supported = supportedLanguages
        guard !supported.contains(selectedLanguage) else { return }
        selectedLanguage = supported.first(where: { $0 == "auto" })
            ?? supported.first(where: { $0 == "en" })
            ?? supported.first ?? "auto"
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var customDictionaryEnabled: Bool {
        didSet {
            AppPreferences.shared.customDictionaryEnabled = customDictionaryEnabled
        }
    }

    @Published var customDictionaryBoostEnabled: Bool {
        didSet {
            AppPreferences.shared.customDictionaryBoostEnabled = customDictionaryBoostEnabled
        }
    }

    @Published var customDictionaryEntries: [CustomDictionaryEntry] {
        didSet {
            AppPreferences.shared.customDictionaryEntries = customDictionaryEntries
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }

    @Published var startHidden: Bool {
        didSet {
            AppPreferences.shared.startHidden = startHidden
        }
    }

    @Published var submitMouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.submitMouseButtonHotkey = submitMouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var submitModifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.submitModifierOnlyHotkey = submitModifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    /// Cancel and paste-last are key-combination only, but the recorder field needs bindings,
    /// so these stay parked at `.none`.
    @Published var cancelMouseButtonUnused: MouseButton = .none
    @Published var cancelModifierUnused: ModifierKey = .none
    @Published var pasteMouseButtonUnused: MouseButton = .none
    @Published var pasteModifierUnused: ModifierKey = .none

    @Published var indicatorMeterMode: String {
        didSet {
            AppPreferences.shared.indicatorMeterMode = indicatorMeterMode
        }
    }

    @Published var indicatorPosition: String {
        didSet {
            AppPreferences.shared.indicatorPosition = indicatorPosition
        }
    }

    @Published var showStopButtonOnIndicator: Bool {
        didSet { AppPreferences.shared.showStopButtonOnIndicator = showStopButtonOnIndicator }
    }

    @Published var showCancelButtonOnIndicator: Bool {
        didSet { AppPreferences.shared.showCancelButtonOnIndicator = showCancelButtonOnIndicator }
    }

    @Published var remoteFallbackEnabled: Bool {
        didSet { AppPreferences.shared.remoteFallbackEnabled = remoteFallbackEnabled }
    }

    @Published var remoteFallbackModel: DictationModelOption? {
        didSet { AppPreferences.shared.remoteFallbackModel = remoteFallbackModel }
    }

    @Published var liveTranscriptionEnabled: Bool {
        didSet {
            AppPreferences.shared.liveTranscriptionEnabled = liveTranscriptionEnabled
        }
    }

    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var mouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.mouseButtonHotkey = mouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }

    @Published var latchRecordingWithSpace: Bool {
        didSet {
            AppPreferences.shared.latchRecordingWithSpace = latchRecordingWithSpace
            // Same notification the trigger modes use: it makes ShortcutManager install or tear
            // down the latch tap immediately, instead of at the next launch.
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var escCancelWithoutConfirmation: Bool {
        didSet {
            AppPreferences.shared.escCancelWithoutConfirmation = escCancelWithoutConfirmation
        }
    }

    @Published var unloadWhisperModelWhenIdle: Bool {
        didSet {
            AppPreferences.shared.unloadWhisperModelWhenIdle = unloadWhisperModelWhenIdle
        }
    }


    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var aiPostProcessingEnabled: Bool {
        didSet {
            AppPreferences.shared.aiPostProcessingEnabled = aiPostProcessingEnabled
            // Surface connectivity right away when the user turns it on, so they aren't left
            // wondering why their cleanup silently does nothing when the server isn't reachable.
            if aiPostProcessingEnabled { testLLMConnection() }
        }
    }

    /// True when anything needs the LLM: prose cleanup or the per-app formatting rules. Both feed
    /// the same backend, so this is what gates the backend UI and its connection probe.
    var llmCleanupInUse: Bool { aiPostProcessingEnabled || appContextFormattingEnabled }

    /// Cleanup backend: "builtin" (embedded llama.cpp), "ollama" (local server), or
    /// "remote" (OpenAI-compatible server).
    @Published var aiBackend: String {
        didSet {
            AppPreferences.shared.aiBackend = aiBackend
            if llmCleanupInUse { testLLMConnection() }
            // Warm the ~1 GB context now, while the user is here in Settings, so their first
            // dictation doesn't wait several seconds for it. Released again after an idle spell.
            if aiBackend == "builtin" { BuiltInLlamaBackend.shared.preload() }
        }
    }

    /// Whether the built-in model's GGUF is present on disk.
    @Published var builtInModelDownloaded: Bool = LLMModelManager.shared.isDefaultModelDownloaded()
    /// Download progress in 0...1 while the built-in model is downloading; nil when idle.
    @Published var builtInModelDownloadProgress: Double?
    /// Set when a built-in model download fails, for inline feedback.
    @Published var builtInModelDownloadError: String?

    /// Downloads the default built-in model (~1 GB), updating progress for the UI.
    func downloadBuiltInModel() {
        builtInModelDownloadError = nil
        builtInModelDownloadProgress = 0
        Task { @MainActor in
            do {
                try await LLMModelManager.shared.downloadDefaultModel { progress in
                    Task { @MainActor in self.builtInModelDownloadProgress = progress }
                }
                self.builtInModelDownloaded = LLMModelManager.shared.isDefaultModelDownloaded()
                // Load it straight away: the download already made them wait, and this keeps the
                // load out of their first dictation.
                BuiltInLlamaBackend.shared.preload()
            } catch {
                self.builtInModelDownloadError = error.localizedDescription
            }
            self.builtInModelDownloadProgress = nil
        }
    }

    @Published var aiOllamaEndpoint: String {
        didSet {
            AppPreferences.shared.aiOllamaEndpoint = aiOllamaEndpoint
        }
    }

    @Published var aiOllamaModel: String {
        didSet {
            AppPreferences.shared.aiOllamaModel = aiOllamaModel
        }
    }

    @Published var aiRemoteEndpoint: String {
        didSet {
            AppPreferences.shared.aiRemoteEndpoint = aiRemoteEndpoint
        }
    }

    @Published var aiRemoteModel: String {
        didSet {
            AppPreferences.shared.aiRemoteModel = aiRemoteModel
        }
    }

    @Published var aiRemoteAPIKey: String {
        didSet {
            AppPreferences.shared.aiRemoteAPIKey = aiRemoteAPIKey.isEmpty ? nil : aiRemoteAPIKey
        }
    }

    @Published var aiPostProcessingPrompt: String {
        didSet {
            AppPreferences.shared.aiPostProcessingPrompt = aiPostProcessingPrompt
        }
    }

    /// Live result of the last cleanup-backend connectivity probe, shown next to the fields.
    @Published var llmStatus: LLMStatus = .unknown

    /// Probes the local Ollama backend. The Remote backend is owned by
    /// RemoteCleanupSettingsView (it also fills the model list), and the built-in backend
    /// has no server to probe (see `builtInModelDownloaded`), so this only runs for Ollama.
    func testLLMConnection() {
        guard aiBackend == "ollama" else { return }
        llmStatus = .checking
        let endpoint = aiOllamaEndpoint, model = aiOllamaModel
        Task { @MainActor in
            self.llmStatus = await LLMPostProcessor.checkOllamaConnection(endpoint: endpoint, model: model)
        }
    }

    /// Prefill the Remote-cleanup fields from the Remote transcription engine's config
    /// (same Groq/OpenAI/LiteLLM server + key is the common case). The chat model is left
    /// for the user — the STT model (whisper…) isn't a chat model.
    func copyRemoteEngineConfig() {
        let prefs = AppPreferences.shared
        aiRemoteEndpoint = prefs.remoteServerURL
        aiRemoteAPIKey = prefs.remoteServerAPIKey ?? ""
    }

    var hasRemoteEngineConfig: Bool {
        !AppPreferences.shared.remoteServerURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @Published var removeFillerWords: Bool {
        didSet {
            AppPreferences.shared.removeFillerWords = removeFillerWords
        }
    }

    @Published var fillerWordsPattern: String {
        didSet {
            AppPreferences.shared.fillerWordsPattern = fillerWordsPattern
        }
    }

    @Published var postRecordHookEnabled: Bool {
        didSet {
            AppPreferences.shared.postRecordHookEnabled = postRecordHookEnabled
        }
    }

    @Published var postRecordHookCommand: String {
        didSet {
            AppPreferences.shared.postRecordHookCommand = postRecordHookCommand
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteTranscription: Bool {
        didSet {
            AppPreferences.shared.autoPasteTranscription = autoPasteTranscription
        }
    }

    @Published var pasteInsteadOfTyping: Bool {
        didSet {
            AppPreferences.shared.pasteInsteadOfTyping = pasteInsteadOfTyping
        }
    }

    @Published var notifyWhenNoPasteTarget: Bool {
        didSet {
            AppPreferences.shared.notifyWhenNoPasteTarget = notifyWhenNoPasteTarget
        }
    }

    @Published var submitOnVoiceCommand: Bool {
        didSet {
            AppPreferences.shared.submitOnVoiceCommand = submitOnVoiceCommand
        }
    }

    /// App-aware LLM formatting: per-app instructions, keyed by the bundle identifier of the app
    /// dictated into, that reshape the transcription via the same LLM cleanup pass (e.g. "at Rob"
    /// -> "@Rob" in Slack). Independent of `aiPostProcessingEnabled`: either can contribute to one
    /// pass. Edited in Settings → Rules; the shared backend is configured in Output → Cleanup.
    @Published var appContextFormattingEnabled: Bool {
        didSet {
            AppPreferences.shared.appContextFormattingEnabled = appContextFormattingEnabled
            // Same reasoning as the general-cleanup toggle: this feature also needs the backend,
            // so probe/warm it now instead of failing silently on the next dictation.
            if appContextFormattingEnabled {
                testLLMConnection()
                if aiBackend == "builtin" { BuiltInLlamaBackend.shared.preload() }
            }
        }
    }

    @Published var appContextProfiles: [AppContextProfile] {
        didSet {
            AppPreferences.shared.appContextProfiles = appContextProfiles
        }
    }

    @Published var pauseMediaOnRecord: Bool {
        didSet {
            AppPreferences.shared.pauseMediaOnRecord = pauseMediaOnRecord
        }
    }

    @Published var reduceVolumeOnRecord: Bool {
        didSet {
            AppPreferences.shared.reduceVolumeOnRecord = reduceVolumeOnRecord
        }
    }

    @Published var reduceVolumeLevel: Double {
        didSet {
            AppPreferences.shared.reduceVolumeLevel = reduceVolumeLevel
        }
    }

    // MARK: - Retention / storage policy

    @Published var retentionMaxCountEnabled: Bool {
        didSet {
            AppPreferences.shared.retentionMaxCountEnabled = retentionMaxCountEnabled
            enforceRetention()
        }
    }

    @Published var retentionMaxCount: Int {
        didSet {
            // Clamp the published property itself (not only the stored value) so the UI and
            // the persisted/enforced value can never diverge. The re-assignment re-enters
            // didSet once with an already-clamped value, which then falls through.
            let clamped = max(1, retentionMaxCount)
            if clamped != retentionMaxCount {
                retentionMaxCount = clamped
                return
            }
            AppPreferences.shared.retentionMaxCount = clamped
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeEnabled: Bool {
        didSet {
            AppPreferences.shared.retentionMaxAgeEnabled = retentionMaxAgeEnabled
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeValue: Int {
        didSet {
            // Clamp the published property itself (see retentionMaxCount) so the UI and the
            // persisted/enforced value can never diverge.
            let clamped = max(1, retentionMaxAgeValue)
            if clamped != retentionMaxAgeValue {
                retentionMaxAgeValue = clamped
                return
            }
            AppPreferences.shared.retentionMaxAgeValue = clamped
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeUnit: RetentionUnit {
        didSet {
            AppPreferences.shared.retentionMaxAgeUnit = retentionMaxAgeUnit.rawValue
            enforceRetention()
        }
    }

    private var retentionEnforceTimer: Timer?

    /// Applies the retention policy after a short debounce so the user sees the effect of
    /// toggling a switch or changing a limit, without the data-loss footgun of enforcing on
    /// every keystroke: the count/age TextFields use `format: .number`, whose binding commits
    /// (and fires didSet) on each parsed value, so typing "500" passes through 5 and 50.
    /// Enforcing immediately would permanently delete recordings at those intermediate values.
    /// Debouncing coalesces a burst of edits into a single enforcement at the final value.
    private func enforceRetention() {
        retentionEnforceTimer?.invalidate()
        retentionEnforceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            Task { @MainActor in
                await RecordingStore.shared.enforceRetentionPolicy()
            }
        }
    }

    @Published var saveTranscriptionHistory: Bool {
        didSet {
            AppPreferences.shared.saveTranscriptionHistory = saveTranscriptionHistory
        }
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.remoteServerURL = prefs.remoteServerURL
        self.remoteServerModel = prefs.remoteServerModel
        self.remoteServerAPIKey = prefs.remoteServerAPIKey ?? ""
        self.remoteServerTimeoutEnabled = prefs.remoteServerTimeoutEnabled
        self.remoteServerTimeoutSeconds = prefs.remoteServerTimeoutSeconds
        self.contextAwareModelMode = prefs.contextAwareModelMode
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.customDictionaryEnabled = prefs.customDictionaryEnabled
        self.customDictionaryBoostEnabled = prefs.customDictionaryBoostEnabled
        self.customDictionaryEntries = prefs.customDictionaryEntries
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.startHidden = prefs.startHidden
        self.indicatorPosition = prefs.indicatorPosition
        self.indicatorMeterMode = prefs.indicatorMeterMode
        self.submitMouseButtonHotkey = MouseButton(rawValue: prefs.submitMouseButtonHotkey) ?? .none
        self.submitModifierOnlyHotkey = ModifierKey(rawValue: prefs.submitModifierOnlyHotkey) ?? .none
        self.showStopButtonOnIndicator = prefs.showStopButtonOnIndicator
        self.showCancelButtonOnIndicator = prefs.showCancelButtonOnIndicator
        self.remoteFallbackEnabled = prefs.remoteFallbackEnabled
        self.remoteFallbackModel = prefs.remoteFallbackModel
        self.liveTranscriptionEnabled = prefs.liveTranscriptionEnabled
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.mouseButtonHotkey = MouseButton(rawValue: prefs.mouseButtonHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.latchRecordingWithSpace = prefs.latchRecordingWithSpace
        self.escCancelWithoutConfirmation = prefs.escCancelWithoutConfirmation
        self.unloadWhisperModelWhenIdle = prefs.unloadWhisperModelWhenIdle
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.aiPostProcessingEnabled = prefs.aiPostProcessingEnabled
        self.aiBackend = prefs.aiBackend
        self.aiOllamaEndpoint = prefs.aiOllamaEndpoint
        self.aiOllamaModel = prefs.aiOllamaModel
        self.aiRemoteEndpoint = prefs.aiRemoteEndpoint
        self.aiRemoteModel = prefs.aiRemoteModel
        self.aiRemoteAPIKey = prefs.aiRemoteAPIKey ?? ""
        self.aiPostProcessingPrompt = prefs.aiPostProcessingPrompt
        self.removeFillerWords = prefs.removeFillerWords
        self.fillerWordsPattern = prefs.fillerWordsPattern
        self.postRecordHookEnabled = prefs.postRecordHookEnabled
        self.postRecordHookCommand = prefs.postRecordHookCommand
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription
        self.pasteInsteadOfTyping = prefs.pasteInsteadOfTyping
        self.notifyWhenNoPasteTarget = prefs.notifyWhenNoPasteTarget
        self.submitOnVoiceCommand = prefs.submitOnVoiceCommand
        self.appContextFormattingEnabled = prefs.appContextFormattingEnabled
        self.appContextProfiles = prefs.appContextProfiles
        self.pauseMediaOnRecord = prefs.pauseMediaOnRecord
        self.reduceVolumeOnRecord = prefs.reduceVolumeOnRecord
        self.reduceVolumeLevel = prefs.reduceVolumeLevel
        self.retentionMaxCountEnabled = prefs.retentionMaxCountEnabled
        self.retentionMaxCount = prefs.retentionMaxCount
        self.retentionMaxAgeEnabled = prefs.retentionMaxAgeEnabled
        self.retentionMaxAgeValue = prefs.retentionMaxAgeValue
        self.retentionMaxAgeUnit = RetentionUnit(rawValue: prefs.retentionMaxAgeUnit) ?? .days
        self.saveTranscriptionHistory = prefs.saveTranscriptionHistory

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()

        // Reflect external model changes (the menu-bar Model picker) while Settings is open.
        modelSyncObserver = NotificationCenter.default.addObserver(
            forName: .modelSelectionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncModelSelectionFromPreferences()
        }
        // Same for the menu-bar Language picker and Translate toggle. The @Published didSets route
        // back through the stores idempotently, so setting the same value here doesn't loop.
        languageSyncObserver = NotificationCenter.default.addObserver(
            forName: .appPreferencesLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.selectedLanguage = AppPreferences.shared.whisperLanguage }
        }
        translateSyncObserver = NotificationCenter.default.addObserver(
            forName: .translateSettingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.translateToEnglish = AppPreferences.shared.translateToEnglish }
        }
    }

    deinit {
        for observer in [modelSyncObserver, languageSyncObserver, translateSyncObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Re-read the active engine/model from AppPreferences (the source of truth) into the
    /// @Published copies, without triggering their write-back/reload side effects. Keeps an
    /// open Settings window in sync when the menu-bar Model picker changes the selection.
    func syncModelSelectionFromPreferences() {
        let prefs = AppPreferences.shared
        let newURL = (prefs.selectedWhisperModelPath ?? prefs.selectedModelPath).map { URL(fileURLWithPath: $0) }
        guard selectedEngine != prefs.selectedEngine
            || fluidAudioModelVersion != prefs.fluidAudioModelVersion
            || remoteServerModel != prefs.remoteServerModel
            || selectedModelURL != newURL else { return }

        isSyncing = true
        selectedEngine = prefs.selectedEngine
        fluidAudioModelVersion = prefs.fluidAudioModelVersion
        remoteServerModel = prefs.remoteServerModel
        selectedModelURL = newURL
        isSyncing = false

        // Refresh the model list shown for the now-active engine.
        if selectedEngine == "whisper" { loadAvailableModels() }
        else if selectedEngine == "fluidaudio" { initializeFluidAudioModels() }
        clampLanguageToSupported()
    }

    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        
        // Используем правильный путь к кэшу согласно документации:
        // ~/Library/Application Support/FluidAudio/Models/<version-folder>/
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        
        // Проверяем наличие всех необходимых файлов модели
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.filename
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        downloadTask = Task {
            do {
                let filename = model.filename
                
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectModel(URL(fileURLWithPath: modelPath))
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.filename
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let models = try await AsrModels.downloadAndLoad(version: version)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    // Just-downloaded model becomes the active selection (persists + reloads
                    // the engine through the single mutation point).
                    selectParakeet(model.version)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0
    /// On-disk filename. Defaults to the URL's basename, but some sources (e.g. the ivrit.ai
    /// model served as a generic `ggml-model.bin`) need an explicit, distinct name.
    let filename: String
    /// Language to switch to when this model is selected (e.g. "he" for the Hebrew model).
    let preferredLanguage: String?

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1000000)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        // Distil large-v3 was here briefly — dropped after our FLEURS benchmark: on
        // Metal it matches large-v3-turbo's speed exactly (the shared large encoder
        // dominates short dictation clips) with worse accuracy (8% vs 5.9% WER) and
        // English only. Anyone who downloaded it keeps using it via the on-disk list.
        SettingsDownloadableModel(
            name: "Hebrew — ivrit.ai Turbo v3",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew-optimized model by ivrit.ai. Selecting it sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    var customDictionaryEnabled: Bool
    var customDictionaryBoostEnabled: Bool
    var customDictionaryEntries: [CustomDictionaryEntry]

    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }

    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    var shouldApplyCustomDictionary: Bool {
        customDictionaryEnabled && !customDictionaryEntries.isEmpty
    }

    /// Whether to also bias recognition toward the dictionary terms (opt-in, on top of the
    /// always-on text replacement). Gated by the separate `customDictionaryBoostEnabled` flag.
    var shouldBoostCustomDictionary: Bool {
        customDictionaryBoostEnabled && shouldApplyCustomDictionary
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.customDictionaryEnabled = prefs.customDictionaryEnabled
        self.customDictionaryBoostEnabled = prefs.customDictionaryBoostEnabled
        self.customDictionaryEntries = prefs.customDictionaryEntries
    }
}

/// A small "ⓘ" button that reveals a longer explanation in a popover, so setting rows can
/// show a short caption by default and keep the full details one click away.
struct InfoButton: View {
    let text: LocalizedStringKey
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("More info")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

/// The settings tabs, shown as a vertical sidebar in the dedicated settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation, models, output, rules, history, advanced, updates, feedback
    var id: String { rawValue }

    /// Main navigation (sidebar top) vs utility items (sidebar footer).
    static let main: [SettingsTab] = [.dictation, .models, .output, .rules, .history, .advanced]
    static let footer: [SettingsTab] = [.updates, .feedback]

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .output: return "Output"
        case .rules: return "Rules"
        case .history: return "History & Privacy"
        case .advanced: return "Advanced"
        case .updates: return "Updates"
        case .feedback: return "Feedback"
        }
    }
    // Icons carried over from the previous sidebar (kept on purpose); "Rules" is the
    // one new tab, so it gets the one new symbol.
    var icon: String {
        switch self {
        case .dictation: return "slider.horizontal.3"
        case .models: return "cpu"
        case .output: return "text.bubble"
        case .rules: return "arrow.triangle.branch"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "gearshape"
        case .updates: return "sparkles"
        case .feedback: return "heart.text.square"
        }
    }
}

struct SettingsView: View {
    struct HookVariable { let name: String; let description: String }
    static let postRecordHookVariables = [
        HookVariable(name: "$OSW_TEXT", description: "the transcription"),
        HookVariable(name: "$OSW_AUDIO_PATH", description: "wav file path (when history is on)"),
        HookVariable(name: "$OSW_TIMESTAMP", description: "ISO 8601 date"),
        HookVariable(name: "$OSW_DURATION", description: "length in seconds"),
    ]

    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: SettingsTab = .dictation
    @State private var sidebarSearch = ""
    @FocusState private var sidebarSearchFocused: Bool
    @State private var availableUpdateTag: String?
    @ObservedObject private var micService = MicrophoneService.shared
    /// The engine whose models are currently being *browsed* (navigation only — the active engine
    /// in `viewModel.selectedEngine` changes only when the user clicks a model).
    @State private var browseEngine: String = AppPreferences.shared.selectedEngine
    @State private var previousModelURL: URL?
    @State private var appLanguage = LanguageManager.selected
    @State private var langNeedsRelaunch = false

    /// Curated cancel-recording keys (the recorder can't capture Esc / single special keys).

    /// One-line description of the selected engine, to help users choose.
    /// Engine → display name for the "active engine" indicator.
    private func engineDisplayName(_ engine: String) -> String {
        switch engine {
        case "fluidaudio": return "Parakeet"
        case "whisper": return "Whisper"
        case "sensevoice": return "SenseVoice"
        case "apple": return "Apple Speech"
        case "remote": return "Remote"
        default: return engine
        }
    }

    /// Short engine name (no model/language suffix) for compact controls.
    private func engineShortName(_ engine: String) -> String {
        switch engine {
        case "fluidaudio": return "Parakeet"
        case "whisper": return "Whisper"
        case "sensevoice": return "SenseVoice"
        case "apple": return "Apple"
        case "remote": return "Remote"
        default: return engine
        }
    }

    private func engineBlurb(for engine: String) -> LocalizedStringKey {
        switch engine {
        case "whisper":
            return "Most accurate, ~99 languages, and can translate to English. Runs fully on-device."
        case "sensevoice":
            return "Fast — Chinese, Cantonese, English, Japanese, Korean. Runs fully on-device."
        case "apple":
            return "macOS's built-in speech model — zero download in the app, managed by the system."
        case "remote":
            return "Cloud / self-hosted — any OpenAI-compatible server (Groq, speaches, LiteLLM, …)."
        default:
            return "Fast, multilingual (25 languages), with a live preview as you speak. Runs fully on-device."
        }
    }

    /// Content for the currently-selected sidebar tab.
    @ViewBuilder private var detailContent: some View {
        switch selectedTab {
        case .dictation: dictationSettings
        case .models:    modelSettings
        case .output:    transcriptionSettings
        case .rules:     AppContextSettingsView(viewModel: viewModel)
        case .history:   storageSettings
        case .advanced:  advancedSettings
        case .updates:   UpdatesView()
        case .feedback:  feedbackSettings
        }
    }

    /// "Feedback" tab — recruit beta testers and route every kind of report (#beta).
    private var feedbackSettings: some View {
        SPane(title: "Feedback", subtitle: "Help us improve") {
            Text("OpenSuperWhisper gets better with your feedback. Hit a bug, or have an idea? Tell us — every report helps make it more stable.")
                .font(.system(size: 12))
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                feedbackLink(
                    title: "Report a bug",
                    subtitle: "On GitHub — steps to reproduce, your macOS version & engine, logs if you have them",
                    icon: "ladybug",
                    url: "https://github.com/my-monkeys/OpenSuperWhisper/issues/new")
                feedbackLink(
                    title: "Send feedback or an idea",
                    subtitle: "A quick form on opensuperwhisper.com — no account needed",
                    icon: "bubble.left.and.bubble.right",
                    url: "https://opensuperwhisper.com/#feedback")
                feedbackLink(
                    title: "Try a beta build",
                    subtitle: "Early features before they ship, on GitHub Releases",
                    icon: "testtube.2",
                    url: "https://github.com/my-monkeys/OpenSuperWhisper/releases")
            }
        }
    }

    private func feedbackLink(title: String, subtitle: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(STheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(STheme.textBright)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(STheme.hint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(STheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One row in the left sidebar. Selection = soft copper tint (design: "teinte douce").
    private func sidebarRow(_ tab: SettingsTab, compact: Bool = false) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundColor(selectedTab == tab ? STheme.accent : STheme.hint)
                Text(tab.title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                Spacer(minLength: 0)
                if tab == .updates && availableUpdateTag != nil {
                    Circle().fill(STheme.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(selectedTab == tab ? STheme.accent : STheme.sidebarItem)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedTab == tab ? STheme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Sidebar tabs matching the search box (matches everything when it's empty).
    private func matchesSearch(_ tab: SettingsTab) -> Bool {
        let q = sidebarSearch.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || tab.title.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Vertical sidebar — search on top, main categories, utility footer
            // (Updates with a badge when one is available, Feedback, Support us, version).
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(STheme.hint)
                    TextField("Search…", text: $sidebarSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(STheme.text)
                        .focused($sidebarSearchFocused)
                    Text("⌘F")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(STheme.hint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(STheme.controlBg))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(STheme.controlBorder, lineWidth: 1))
                .padding(.bottom, 12)
                .background(
                    Button("") { sidebarSearchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                )

                ForEach(SettingsTab.main.filter(matchesSearch)) { tab in
                    sidebarRow(tab)
                }
                Spacer(minLength: 0)

                Rectangle().fill(STheme.border).frame(height: 1).padding(.vertical, 8)
                ForEach(SettingsTab.footer.filter(matchesSearch)) { tab in
                    sidebarRow(tab, compact: true)
                }
                Button {
                    if let url = URL(string: "https://ko-fi.com/mymonkey") { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "heart")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 18, alignment: .center)
                            .foregroundColor(STheme.hint)
                        Text("Support us").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(STheme.sidebarItem)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Link(destination: URL(string: "https://github.com/my-monkeys/OpenSuperWhisper")!) {
                        HStack(spacing: 6) {
                            Image("github-mark")
                                .resizable()
                                .renderingMode(.template)
                                .frame(width: 13, height: 13)
                            Text("v\(UpdateChecker.currentVersion)")
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        .foregroundColor(STheme.hint.opacity(0.8))
                        .contentShape(Rectangle())
                    }
                    .help("GitHub")
                    Spacer()
                    Link(destination: URL(string: "https://github.com/my-monkeys/OpenSuperWhisper")!) {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                            .foregroundColor(STheme.hint.opacity(0.8))
                    }
                    .help("Star us on GitHub")
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .padding(12)
            .frame(width: 224)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(STheme.sidebarBg)
            .task {
                if let releases = try? await UpdateChecker.fetchReleases() {
                    availableUpdateTag = UpdateChecker.availableUpdate(in: releases)?.tagName
                }
            }

            Rectangle().fill(STheme.border).frame(width: 1)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(STheme.windowBg)
                // The old footer's Done button carried this legacy reload; the window now
                // just closes, so run it when the view goes away instead. (Model selection
                // reloads through ModelSelectionStore anyway — this is belt-and-suspenders
                // for a Whisper path that predates the stores.)
                .onDisappear {
                    if viewModel.selectedEngine == "whisper",
                       viewModel.selectedModelURL != previousModelURL,
                       let modelPath = viewModel.selectedModelURL?.path {
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
        }
        .tint(STheme.accent)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 540, idealHeight: 600)
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            launchAtLogin.refresh()
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }
    
    /// Compact engine card (design 1b): name + one-line subtitle, copper when browsed.
    private func engineCard(tag: String, name: String, sub: LocalizedStringKey) -> some View {
        Button { browseEngine = tag } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(browseEngine == tag ? STheme.accent : STheme.text)
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(browseEngine == tag ? STheme.accentSoft : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(browseEngine == tag ? STheme.accent : STheme.controlBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "● Active · Engine / model" pill (green — the one live-status element).
    private var activeModelPill: some View {
        let model = ModelCatalog.activeOption()?.displayName
        return Text("● Active · \(engineDisplayName(viewModel.selectedEngine))\(model.map { " / \($0)" } ?? "")")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(STheme.ok)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(STheme.okBg))
            .frame(maxWidth: 340, alignment: .trailing)
    }

    /// Shared "downloading…" progress block for the local-engine lists.
    @ViewBuilder private var downloadProgressBlock: some View {
        if viewModel.isDownloading {
            HStack(spacing: 12) {
                if viewModel.downloadProgress > 0 {
                    ProgressView(value: viewModel.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(STheme.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let downloadingName = viewModel.downloadingModelName {
                    Text(downloadingName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(STheme.hint)
                        .lineLimit(1)
                }
                Button("Cancel") { viewModel.cancelDownload() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
        }
    }

    /// Models-directory row (Storage section of the local engines).
    private func storageSection(path: String, open: @escaping () -> Void) -> some View {
        SSection(title: "Storage") {
            SRow(title: "Models directory", hint: LocalizedStringKey(path)) {
                Button("Open in Finder", action: open)
                    .controlSize(.small)
            }
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Models")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(STheme.textBright)
                Spacer()
                activeModelPill
            }
            .padding(.horizontal, 24).padding(.top, 16)

            HStack(spacing: 8) {
                engineCard(tag: "fluidaudio", name: "Parakeet", sub: "Fast, on-device")
                engineCard(tag: "whisper", name: "Whisper", sub: "Accurate · 99 langs")
#if arch(arm64)
                engineCard(tag: "sensevoice", name: "SenseVoice", sub: "zh · yue · ja · ko")
#endif
                if AppleSpeechSupport.isSupported {
                    engineCard(tag: "apple", name: "Apple", sub: "Built into macOS")
                }
                engineCard(tag: "remote", name: "Remote", sub: "Your own server")
            }
            .padding(.horizontal, 24).padding(.top, 12)

            if browseEngine == "remote" {
                HStack(spacing: 8) {
                    Text("⚠︎")
                    Text("Audio is uploaded to the remote server — not necessarily on-device.")
                }
                .font(.system(size: 11.5))
                .foregroundColor(STheme.warn)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.warnBg))
                .padding(.horizontal, 24).padding(.top, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if browseEngine == "whisper" {
                        SSection(title: "Whisper models") {
                            VStack(spacing: 8) {
                                ForEach($viewModel.downloadableModels) { $model in
                                    ModelDownloadItemView(model: $model, viewModel: viewModel)
                                }
                            }
                            downloadProgressBlock
                        }
                        storageSection(path: WhisperModelManager.shared.modelsDirectory.path) {
                            NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                        }
                        SSection(title: "Memory") {
                            SRow(title: "Unload model when idle",
                                 hint: "Free the model (~1 GB) between dictations and reload it on demand — saves RAM, adds a little start latency") {
                                SToggle(isOn: $viewModel.unloadWhisperModelWhenIdle)
                            }
                        }
                    } else if browseEngine == "fluidaudio" {
                        SSection(title: "Parakeet models") {
                            VStack(spacing: 8) {
                                ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                    FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                                }
                            }
                            downloadProgressBlock
                        }
                        storageSection(path: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent().path) {
                            NSWorkspace.shared.open(AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
                        }
                    }
#if arch(arm64)
                    if browseEngine == "sensevoice" {
                        SenseVoiceModelSection(viewModel: viewModel)
                    }
#endif
#if canImport(FoundationModels)
                    if browseEngine == "apple", #available(macOS 26.0, *) {
                        AppleSpeechModelSection(viewModel: viewModel)
                    }
#endif
                    if browseEngine == "remote" {
                        RemoteSettingsSection(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .background(STheme.windowBg)
    }

    /// Small themed text input used across the Output pane.
    private func sInput(_ text: Binding<String>, prompt: String, width: CGFloat, mono: Bool = false) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: mono ? .monospaced : .default))
            .autocorrectionDisabled(true)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
    }

    /// Themed multiline editor (regex, prompts, instructions). See `SEditor`, shared with
    /// the Rules pane.
    private func sEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        SEditor(text: text, height: height)
    }

    @ViewBuilder private var ollamaCleanupFields: some View {
        SRow(title: "Model", indented: true) {
            sInput($viewModel.aiOllamaModel, prompt: "llama3.2", width: 170, mono: true)
        }
        SRow(title: "Endpoint", indented: true) {
            HStack(spacing: 8) {
                Button("Test") { viewModel.testLLMConnection() }
                    .controlSize(.small)
                sInput($viewModel.aiOllamaEndpoint, prompt: "http://localhost:11434", width: 210, mono: true)
            }
        }
    }

    @ViewBuilder private var builtInCleanupFields: some View {
        HStack(spacing: 8) {
            if viewModel.builtInModelDownloaded {
                Text("✓ Model ready — runs on-device")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(STheme.ok)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Capsule().fill(STheme.okBg))
                Text("Loads on first use (a few seconds), then frees its ~1 GB after 5 minutes idle.")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = viewModel.builtInModelDownloadProgress {
                ProgressView(value: progress).frame(width: 160).controlSize(.small)
                Text("\(Int(progress * 100))%").font(.system(size: 11)).foregroundColor(STheme.hint)
            } else {
                Button("Download model (~1 GB)") { viewModel.downloadBuiltInModel() }
                    .controlSize(.small)
                Text("Qwen2.5 1.5B, Apache-2.0. One-time download; no server needed.")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.leading, 16)
        if let err = viewModel.builtInModelDownloadError {
            Text("✕ \(err)")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
        }
    }

    @ViewBuilder private var llmStatusView: some View {
        let isRemote = viewModel.aiBackend == "remote"
        switch viewModel.llmStatus {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Text("✓ Connected — model ready")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(STheme.ok)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Capsule().fill(STheme.okBg))
        case .modelMissing(let model):
            Text(isRemote
                ? "Reachable, but “\(model)” isn't in the server's model list"
                : "Reachable, but “\(model)” isn't pulled — run: ollama pull \(model)")
                .font(.system(size: 11))
                .foregroundColor(STheme.warn)
                .fixedSize(horizontal: false, vertical: true)
        case .authFailed:
            Text("✕ The server rejected the API key")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable:
            Text(isRemote
                ? "✕ Can't reach the server — check the URL"
                : "✕ Can't reach Ollama — is it running? (ollama serve)")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptionSettings: some View {
        SPane(title: "Output", subtitle: "What happens to your text, in pipeline order") {
            SSection(title: "Language") {
                SRow(title: "Transcription language") {
                    Picker("", selection: $viewModel.selectedLanguage) {
                        ForEach(viewModel.supportedLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                        }
                    }
                    // Recreate the picker when the engine's language set changes, so its
                    // selection never gets stuck blank on a value that left the list; and
                    // clamp the stored language to a supported one when this view appears.
                    .id(viewModel.supportedLanguages)
                    .onAppear { viewModel.clampLanguageToSupported() }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                SRow(title: "Translate to English",
                     hint: !viewModel.canTranslate
                        ? "Only Whisper and remote servers translate; the current engine ignores this."
                        : (viewModel.translateToEnglish && viewModel.selectedEngine == "remote"
                            ? "We can't confirm this remote model supports translation"
                            : nil),
                     hintColor: viewModel.translateToEnglish && viewModel.selectedEngine == "remote" ? STheme.warn : STheme.hint) {
                    SToggle(isOn: $viewModel.translateToEnglish, disabled: !viewModel.canTranslate)
                }
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    SRow(title: "Asian autocorrect", hint: "Fixes CJK spacing") {
                        SToggle(isOn: $viewModel.useAsianAutocorrect)
                    }
                }
            }

            SSection(title: "Guidance") {
                SRow(title: "Initial prompt", hint: "Optional text to guide the model's transcription") { EmptyView() }
                sEditor($viewModel.initialPrompt, height: 48)
            }

            SSection(title: "Cleanup") {
                SRow(title: "Remove filler words", hint: "Strip um, uh, er… before inserting") {
                    SToggle(isOn: $viewModel.removeFillerWords)
                }
                if viewModel.removeFillerWords {
                    VStack(alignment: .leading, spacing: 4) {
                        sEditor($viewModel.fillerWordsPattern, height: 48)
                        Text("Case-insensitive regex, applied before pasting.")
                            .font(.system(size: 11)).foregroundColor(STheme.hint)
                    }
                    .padding(.leading, 16)
                }
                HStack(spacing: 8) {
                    Text("Clean up with an LLM")
                        .font(.system(size: 13)).foregroundColor(STheme.text)
                    Spacer()
                    SToggle(isOn: $viewModel.aiPostProcessingEnabled)
                }
                .frame(minHeight: 26)
                // One backend serves BOTH this prose cleanup and the per-app formatting rules in
                // Settings → Rules, so it stays visible while either is on — otherwise someone
                // using formatting only would have nowhere to pick a backend or download a model.
                if viewModel.aiPostProcessingEnabled || viewModel.appContextFormattingEnabled {
                    SRow(title: "Backend", indented: true) {
                        Picker("", selection: $viewModel.aiBackend) {
                            Text("Built-in (Qwen2.5 1.5B)").tag("builtin")
                            Text("Ollama (local)").tag("ollama")
                            Text("Remote (OpenAI-compatible)").tag("remote")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    if !viewModel.aiPostProcessingEnabled {
                        Text("Used by the per-app formatting rules in Rules.")
                            .font(.system(size: 11)).foregroundColor(STheme.hint)
                            .padding(.leading, 16)
                    }

                    switch viewModel.aiBackend {
                    case "builtin":
                        builtInCleanupFields
                    case "remote":
                        RemoteCleanupSettingsView(viewModel: viewModel)
                    default:
                        ollamaCleanupFields
                    }

                    if viewModel.aiBackend != "builtin" {
                        HStack { Spacer(); llmStatusView }
                            .padding(.leading, 16)
                    }
                }
                if viewModel.aiPostProcessingEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instruction").font(.system(size: 11)).foregroundColor(STheme.hint)
                        sEditor($viewModel.aiPostProcessingPrompt, height: 64)
                    }
                    .padding(.leading, 16)
                }
            }

            SSection(title: "Dictionary") {
                SRow(title: "Custom dictionary", hint: "Whole-word replacement, case-insensitive") {
                    SToggle(isOn: $viewModel.customDictionaryEnabled)
                }
                if viewModel.customDictionaryEnabled {
                    HStack(spacing: 8) {
                        Text("Boost recognition")
                            .font(.system(size: 12)).foregroundColor(STheme.text)
                        STag("Advanced")
                        InfoButton(text: "Also bias the model toward these terms while listening, not just fix them afterward. Helps rare, distinctive words (e.g. “Kubernetes”) — but can over-correct short, common ones. Leave off if it replaces too much.")
                        Spacer()
                        SToggle(isOn: $viewModel.customDictionaryBoostEnabled)
                    }
                    .padding(.leading, 16)
                    .frame(minHeight: 24)

                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("Heard").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Replace with").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 24, height: 1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(STheme.sectionTitle)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(STheme.controlBg.opacity(0.6))

                        if viewModel.customDictionaryEntries.isEmpty {
                            Text("No words yet. Add one below.")
                                .font(.system(size: 11)).foregroundColor(STheme.hint)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 14)
                        }
                        ForEach($viewModel.customDictionaryEntries) { $entry in
                            HStack(spacing: 10) {
                                TextField("", text: $entry.original, prompt: Text("git hub"))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity)
                                Text("→").font(.system(size: 11)).foregroundColor(STheme.hint)
                                TextField("", text: $entry.replacement, prompt: Text("GitHub"))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity)
                                Button {
                                    viewModel.customDictionaryEntries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(STheme.hint)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this entry")
                                .frame(width: 24)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            Rectangle().fill(STheme.border).frame(height: 1)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .padding(.leading, 16)

                    Button {
                        viewModel.customDictionaryEntries.append(CustomDictionaryEntry())
                    } label: {
                        Label("Add word", systemImage: "plus")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .controlSize(.small)
                    .padding(.leading, 16)
                }
            }

            SSection(title: "Delivery") {
                SRow(title: "Copy to clipboard", hint: "Also place the transcription on the clipboard. When off, the previous clipboard contents are preserved") {
                    SToggle(isOn: $viewModel.autoCopyToClipboard)
                }
                SRow(title: "Auto-paste transcription", hint: "Insert the transcription into the focused app") {
                    SToggle(isOn: $viewModel.autoPasteTranscription)
                }
                SRow(title: "Paste instead of typing",
                     hint: "⌘V instead of synthetic keystrokes — helps in Electron apps and Messages") {
                    SToggle(isOn: $viewModel.pasteInsteadOfTyping)
                }
                SRow(title: "Notify when no paste target",
                     hint: "\"Copied — press ⌘V\" if no text field is focused") {
                    SToggle(isOn: $viewModel.notifyWhenNoPasteTarget)
                }
                SRow(title: "Submit on “press enter”",
                     hint: "Saying “press enter” at the end presses Return — submitting in Claude Code, Slack, etc.") {
                    SToggle(isOn: $viewModel.submitOnVoiceCommand)
                }
                SRow(title: "Show timestamps") {
                    SToggle(isOn: $viewModel.showTimestamps)
                }
                SRow(title: "Suppress blank audio") {
                    SToggle(isOn: $viewModel.suppressBlankAudio)
                }
                SRow(title: "Add space after sentence", hint: "Useful when dictating in bursts") {
                    SToggle(isOn: $viewModel.addSpaceAfterSentence)
                }
            }
        }
    }

    private var storageSettings: some View {
        SPane(title: "History & Privacy") {
            SSection(title: "Privacy") {
                SRow(title: "Save transcription history",
                     hint: "Off = nothing is ever written to disk — only the current transcription is kept in memory for pasting") {
                    SToggle(isOn: $viewModel.saveTranscriptionHistory)
                }
                SRow(title: "Transcriptions directory",
                     hint: LocalizedStringKey(Recording.recordingsDirectory.path)) {
                    Button("Open in Finder") { NSWorkspace.shared.open(Recording.recordingsDirectory) }
                        .controlSize(.small)
                }
            }

            SSection(title: "Retention") {
                SRow(title: "Limit number of recordings",
                     hint: "Keep only the most recent recordings & transcriptions") {
                    SToggle(isOn: $viewModel.retentionMaxCountEnabled)
                }
                if viewModel.retentionMaxCountEnabled {
                    SRow(title: "Keep at most", indented: true) {
                        HStack(spacing: 6) {
                            TextField("", value: $viewModel.retentionMaxCount, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .frame(width: 64)
                                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
                            Stepper("", value: $viewModel.retentionMaxCount, in: 1...100000)
                                .labelsHidden()
                            Text("recordings").font(.system(size: 11)).foregroundColor(STheme.hint)
                        }
                    }
                }
                SRow(title: "Delete old recordings",
                     hint: "Automatically remove recordings older than the chosen age") {
                    SToggle(isOn: $viewModel.retentionMaxAgeEnabled)
                }
                if viewModel.retentionMaxAgeEnabled {
                    SRow(title: "Delete after", indented: true) {
                        HStack(spacing: 6) {
                            TextField("", value: $viewModel.retentionMaxAgeValue, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .frame(width: 56)
                                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
                            Stepper("", value: $viewModel.retentionMaxAgeValue, in: 1...100000)
                                .labelsHidden()
                            Picker("", selection: $viewModel.retentionMaxAgeUnit) {
                                ForEach(RetentionUnit.allCases, id: \.self) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                Text("Both limits combine — whichever is hit first wins. Cleanup runs automatically, never while a transcription is being processed.")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Advanced" — the redesigned engine-internals screen (Settings Explorations 2e):
    /// App / Decoding / Model parameters / Post-record hook / Debug, in the Atelier style.
    private var advancedSettings: some View {
        SPane(title: "Advanced") {
            SSection(title: "App") {
                SRow(title: "App language", hint: "Relaunch to apply.") {
                    Picker("", selection: $appLanguage) {
                        Text("System").tag("system")
                        Text("English").tag("en")
                        Text("Français").tag("fr")
                        Text("Deutsch").tag("de")
                        Text("Español").tag("es")
                        Text("Italiano").tag("it")
                        Text("Português (BR)").tag("pt-BR")
                        Text("Tiếng Việt").tag("vi")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .labelsHidden()
                    .onChange(of: appLanguage) { _, newValue in
                        LanguageManager.selected = newValue
                        langNeedsRelaunch = true
                    }
                }
                if langNeedsRelaunch {
                    SRow(title: "Relaunch to apply the new language", indented: true) {
                        Button("Relaunch Now") { LanguageManager.relaunch() }
                            .controlSize(.small)
                    }
                }
                SRow(title: "Launch at login", hint: "Start OpenSuperWhisper automatically when you log in.") {
                    SToggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                }
                SRow(title: "Start in the menu bar", hint: "Launch without the main window — open it from the menu bar icon.") {
                    SToggle(isOn: $viewModel.startHidden)
                }
            }

            SSection(title: "Decoding") {
                SRow(title: "Use beam search", hint: "Can improve accuracy, at some speed cost.") {
                    SToggle(isOn: $viewModel.useBeamSearch)
                }
                if viewModel.useBeamSearch {
                    SRow(title: "Beam size", indented: true) {
                        Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(STheme.text)
                            .frame(width: 90)
                    }
                }
            }

            SSection(title: "Model parameters") {
                VStack(alignment: .leading, spacing: 2) {
                    SRow(title: "Temperature", hint: "Higher values make decoding more random.") {
                        Text(String(format: "%.2f", viewModel.temperature))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(STheme.hint)
                    }
                    Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SRow(title: "No speech threshold", hint: "How confident the model must be to call a segment silence.") {
                        Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(STheme.hint)
                    }
                    Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                        .controlSize(.small)
                }
            }

            SSection(title: "Post-record hook") {
                SRow(title: "Run a command after each transcription", hint: "Launch your own script when a transcription completes.") {
                    HStack(spacing: 8) {
                        InfoButton(text: "Runs via /bin/sh -c after each successful transcription, in the background. Your command receives the data as environment variables — OSW_TEXT, OSW_AUDIO_PATH (when history is on), OSW_TIMESTAMP, OSW_DURATION — and a JSON object on stdin with the same fields. Example: echo \"$OSW_TEXT\" >> ~/dictations.txt")
                        SToggle(isOn: $viewModel.postRecordHookEnabled)
                    }
                }
                if viewModel.postRecordHookEnabled {
                    sEditor($viewModel.postRecordHookCommand, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available in your command (also piped as JSON on stdin):")
                            .font(.system(size: 11))
                            .foregroundColor(STheme.hint)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Self.postRecordHookVariables, id: \.name) { variable in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(variable.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(STheme.text)
                                Text("— \(variable.description)")
                                    .font(.system(size: 11))
                                    .foregroundColor(STheme.hint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            SSection(title: "Debug") {
                SRow(title: "Debug mode", hint: "Extra logging and diagnostic output.") {
                    SToggle(isOn: $viewModel.debugMode)
                }
            }
        }
    }

    /// The three recording-trigger modes are mutually exclusive; a bound mouse button
    /// wins over a modifier key, which wins over the regular key-combination shortcut.
    /// "Dictation" — the redesigned first screen (Settings Explorations 2a):
    /// Trigger / Recording bar / Input, in the Atelier style.
    private var dictationSettings: some View {
        SPane(title: "Dictation") {
            SSection(title: "Trigger") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording trigger")
                        .font(.system(size: 13))
                        .foregroundColor(STheme.text)
                    Text("Click Add, then do the thing: press a combination with ⌘ ⌥ ⌃, tap a single modifier on its own, or click a spare mouse button. Keep several and use whichever suits the moment.")
                        .font(.system(size: 11))
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                    TriggerRecorderField(name: .toggleRecord,
                                         mouseButton: $viewModel.mouseButtonHotkey,
                                         modifierKey: $viewModel.modifierOnlyHotkey,
                                         allowsMultiple: true)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SRow(title: "Latch with Space",
                     hint: "While recording, Space (or a double-tap of the trigger) pins it so you can let go and keep talking. Space again stops it — so Space won't type into other apps during a recording") {
                    SToggle(isOn: $viewModel.latchRecordingWithSpace)
                }
                if viewModel.latchRecordingWithSpace {
                    SWarnBox {
                        Text("**⚠︎ Accessibility permission required.** macOS needs it to see the Space key globally. Space is only intercepted while a recording is running — at any other time it types normally, and no other keystrokes are captured.")
                        Button("Open Accessibility Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(STheme.warn)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.warnBorder, lineWidth: 1))
                    }
                }
                SRow(title: "Paste last transcription",
                     hint: "Inserts your most recent transcription again, wherever the cursor is. Unbound by default — ⌫ clears it") {
                    TriggerRecorderField(name: .pasteLastTranscription,
                                         mouseButton: $viewModel.pasteMouseButtonUnused,
                                         modifierKey: $viewModel.pasteModifierUnused,
                                         allowsMouse: false,
                                         allowsModifier: false)
                        .frame(width: 168)
                }
                SRow(title: "Cancel shortcut",
                     hint: "Discards the recording. Esc on its own is fine here; ⌫ clears it") {
                    TriggerRecorderField(name: .escape,
                                         mouseButton: $viewModel.cancelMouseButtonUnused,
                                         modifierKey: $viewModel.cancelModifierUnused,
                                         allowsMouse: false,
                                         allowsModifier: false,
                                         allowsBareEscape: true)
                        .frame(width: 168)
                }
                SRow(title: "Stop and submit",
                     hint: "Ends the recording and presses Return, so the message sends itself. Only works while recording — it never starts one. Unbound by default; ⌫ clears it") {
                    TriggerRecorderField(name: .toggleRecordAndSubmit,
                                         mouseButton: $viewModel.submitMouseButtonHotkey,
                                         modifierKey: $viewModel.submitModifierOnlyHotkey)
                        .frame(width: 168)
                }
                SRow(title: "Cancel without confirmation",
                     hint: "Skip the double-Esc confirmation for recordings longer than 10 seconds") {
                    SToggle(isOn: $viewModel.escCancelWithoutConfirmation)
                }
                SRow(title: "Hold to record", hint: "Hold the shortcut to record, release to stop") {
                    SToggle(isOn: $viewModel.holdToRecord)
                }
            }

            SSection(title: "While recording") {
                SRow(title: "Play sound when recording starts",
                     hint: "Also plays when a recording is latched hands-free") {
                    SToggle(isOn: $viewModel.playSoundOnRecordStart)
                }
                HStack(spacing: 8) {
                    Text("Live transcription")
                        .font(.system(size: 13))
                        .foregroundColor(STheme.text)
                        .opacity(viewModel.selectedEngine == "fluidaudio" ? 1 : 0.45)
                    STag("Parakeet only")
                    Spacer()
                    SToggle(isOn: $viewModel.liveTranscriptionEnabled,
                            disabled: viewModel.selectedEngine != "fluidaudio")
                }
                .frame(minHeight: 26)
                SRow(title: "Pause media during recording",
                     hint: "Resumes what was actually playing when you stop") {
                    SToggle(isOn: $viewModel.pauseMediaOnRecord)
                }
                SRow(title: "Lower system volume while recording") {
                    SToggle(isOn: $viewModel.reduceVolumeOnRecord)
                }
                if viewModel.reduceVolumeOnRecord {
                    SRow(title: "Volume while recording", indented: true) {
                        HStack(spacing: 10) {
                            Slider(value: $viewModel.reduceVolumeLevel, in: 0...0.5)
                                .controlSize(.small)
                                .frame(width: 150)
                                .tint(STheme.accent)
                            Text("\(Int(viewModel.reduceVolumeLevel * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(STheme.hint)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }

            SSection(title: "Input") {
                SRow(title: "Microphone",
                     hint: micService.followsSystemDefault
                        ? "Following the system input\(micService.currentMicrophone.map { " (\($0.name))" } ?? "") — switch headsets and it follows"
                        : "Also switchable from the menu bar") {
                    Picker("", selection: Binding(
                        get: {
                            micService.followsSystemDefault
                                ? MicrophoneService.systemDefaultID
                                : (micService.selectedMicrophone?.id ?? MicrophoneService.systemDefaultID)
                        },
                        set: { newID in
                            if newID == MicrophoneService.systemDefaultID {
                                micService.resetToDefault()
                            } else if let device = micService.availableMicrophones.first(where: { $0.id == newID }) {
                                micService.selectMicrophone(device)
                            }
                        }
                    )) {
                        Text("System Default").tag(MicrophoneService.systemDefaultID)
                        Divider()
                        ForEach(micService.availableMicrophones, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SSection(title: "Indicator") {
                IndicatorLayoutEditor(viewModel: viewModel)
            }
        }
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    var size: Int = 0   // approximate download size, MB
    var downloadProgress: Double = 0.0

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1_000_000)
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 461
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 460
        )
    ]
}

enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0
}

struct OnboardingUnifiedModels {
    static let availableModels = [
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]
}

struct FluidAudioModelDownloadItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }

    /// The model actually used for transcription: selected *and* its engine is active.
    /// Only the active model shows the solid green check (resolves the two-checkmarks
    /// ambiguity of #139).
    var isActive: Bool {
        isSelected && viewModel.selectedEngine == "fluidaudio"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }
                
                HStack(spacing: 6) {
                    Text(model.description)
                    Text("·")
                    Text(model.sizeString)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.7)
                        .padding(.top, 4)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    // Not the active model → offer Select. One global selection, so a
                    // non-active model shows no "remembered" checkmark (selecting here
                    // activates Parakeet and deselects other engines).
                    Button(action: {
                        viewModel.selectParakeet(model.version)
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadFluidAudioModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(isActive ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Activate on tap whenever this isn't already the *active* model — even if it's the
            // selected version but Parakeet isn't the active engine (browse ≠ select).
            if model.isDownloaded && !isActive {
                viewModel.selectParakeet(model.version)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct ModelDownloadItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        if let selectedURL = viewModel.selectedModelURL {
            let filename = model.filename
            return selectedURL.lastPathComponent == filename
        }
        return false
    }

    /// The model actually used for transcription: selected *and* Whisper is the
    /// active engine. Only the active model shows the solid green check (#139).
    var isActive: Bool {
        isSelected && viewModel.selectedEngine == "whisper"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }

                HStack(spacing: 6) {
                    Text(model.description)
                    Text("·")
                    Text(model.sizeString)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }

            Spacer()

            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    // Not the active model → offer Select. The app has one global
                    // selection, so a non-active model shows no "remembered" checkmark
                    // (selecting here activates Whisper and deselects other engines).
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                        viewModel.selectModel(URL(fileURLWithPath: modelPath))
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(isActive ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Activate on tap whenever this isn't the active model (works even if it's the selected
            // file but Whisper isn't the active engine).
            if model.isDownloaded && !isActive {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                viewModel.selectModel(URL(fileURLWithPath: modelPath))
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

