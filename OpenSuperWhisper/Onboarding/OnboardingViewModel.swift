import Foundation
import SwiftUI
import FluidAudio
import OpenSuperWhisperCore

enum OnboardingShortcutOption: String, CaseIterable {
    case keyCombination
    case rightOption
    /// A key, combination or mouse button the user records in the step.
    case custom
}

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            suggestDefaultModel()
            Task { @MainActor in await refreshAppleSpeech() }
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    /// Only the card on screen: the choice reaches the app when the step is left (see
    /// `applyShortcutChoice`), since re-arming the key monitors on every click made the cards lag.
    @Published var selectedShortcut: OnboardingShortcutOption

    /// What the Custom card recorded. Recording something picks that card.
    @Published var customTrigger: RecordingTrigger? {
        didSet {
            if customTrigger != nil && selectedShortcut != .custom { selectedShortcut = .custom }
        }
    }

    /// The combination the second card offers: the one the list held when onboarding opened,
    /// so recording a custom one (which takes its place in the list) never relabels the card.
    let combination: RecordingTrigger?
    /// The recorded trigger last written to the list, taken out again when the choice changes.
    var appliedCustom: RecordingTrigger?
    /// What the app listens to now: the choice it opened with, until a different one is applied.
    var appliedChoice = OnboardingShortcutChoice(option: .keyCombination, custom: nil)

    @Published var unifiedModels: [OnboardingUnifiedModel] = []
    @Published var selectedModelId: UUID?
    @Published var remoteSelected: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    /// What Apple's speech model offers for `selectedLanguage`. Read asynchronously, so it
    /// starts unavailable and the step redraws once the system has answered.
    @Published private(set) var appleSpeech: AppleSpeechOffer = .unavailable

    /// The words the "Your words" step holds, written to the dictionary only by `commitWords`.
    @Published var words: [String] = []
    /// What is typed in that step's field and not yet turned into a chip.
    @Published var wordDraft = ""

    private let modelManager = WhisperModelManager.shared
    let system: OnboardingSystem
    private var downloadTask: Task<Void, Error>?
    /// Set once the user picks a model, a server or a download. From then on the default
    /// stops following the language picker.
    private var userChoseModel = false
    /// Apple's row, kept so its identity (and so a selection of it) survives being taken out
    /// of the list and put back when the language changes.
    private let appleSpeechModel = OnboardingUnifiedModel(
        name: "Apple Speech", isDownloaded: false, description: "", type: .appleSpeech)

    init(system: OnboardingSystem = .live) {
        self.system = system
        let language = OnboardingLanguageDefault.pick(appLanguage: system.appLanguage,
                                                      preferredLanguages: system.preferredLanguages,
                                                      available: LanguageUtil.availableLanguages)
        AppPreferences.shared.whisperLanguage = language
        self.selectedLanguage = language
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        self.combination = RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers)
            .keyCombos.first.map { .keyCombo($0) }

        let currentHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if currentHotkey == .none && !AppPreferences.shared.hasCompletedOnboarding {
            // Default to key combination mode — does NOT require Input Monitoring permission.
            // Users can switch to single modifier key mode later in Settings if they prefer.
            self.selectedShortcut = .keyCombination
            AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        } else {
            self.selectedShortcut = currentHotkey == .rightOption ? .rightOption : .keyCombination
        }
        appliedChoice = pendingChoice
        
        initializeUnifiedModels()
        Task { @MainActor in await refreshAppleSpeech() }
    }

    func initializeUnifiedModels() {
        unifiedModels = OnboardingUnifiedModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = system.isDownloaded(model.type)
            return updatedModel
        }
        suggestDefaultModel()
    }

    /// Asks the system what Apple's model offers for the language, then puts its row first or
    /// takes it out. Answers for a language the picker has since left are dropped.
    @MainActor
    func refreshAppleSpeech() async {
        let language = selectedLanguage
        let offer = await system.appleSpeech(language)
        guard language == selectedLanguage else { return }
        appleSpeech = offer
        unifiedModels.removeAll(where: \.isAppleSpeech)
        if offer != .unavailable {
            unifiedModels.insert(appleSpeechModel, at: 0)
        } else if selectedModelId == appleSpeechModel.id {
            // Its row is gone: the choice no longer stands, so the default takes over again.
            selectedModelId = nil
            userChoseModel = false
        }
        suggestDefaultModel()
    }

    /// Preselects `OnboardingModelDefault`'s pick and follows the language picker, until the
    /// user chooses for themselves.
    private func suggestDefaultModel() {
        guard !remoteSelected, !userChoseModel else { return }
        guard let model = OnboardingModelDefault.pick(from: unifiedModels, language: selectedLanguage,
                                                      appleSpeech: appleSpeech)
        else { return }
        activate(model)
    }

    static func isDefaultCandidate(_ model: OnboardingUnifiedModel, language: String) -> Bool {
        switch model.type {
        case .parakeet(let version):
            return language == "auto" || EngineCapabilities.supportedLanguages(
                engine: "fluidaudio", fluidAudioModelVersion: version).contains(language)
        case .whisper:
            return true
        case .senseVoice, .appleSpeech:
            return false
        }
    }
    
    /// Apple's model needs nothing from the app, even when macOS still has to fetch the
    /// language: it does that itself on first use.
    var canContinue: Bool {
        if remoteSelected { return true }
        guard let selectedId = selectedModelId else { return false }
        return unifiedModels.contains { $0.id == selectedId && ($0.isDownloaded || $0.isAppleSpeech) }
    }

    // Selecting a remote (OpenAI-compatible) server skips the local-model
    // requirement entirely; the endpoint/key are configured later in Settings.
    func selectRemote() {
        userChoseModel = true
        remoteSelected = true
        selectedModelId = nil
        AppPreferences.shared.selectedEngine = "remote"
    }

    func selectModel(_ model: OnboardingUnifiedModel) {
        userChoseModel = true
        activate(model)
    }

    private func activate(_ model: OnboardingUnifiedModel) {
        remoteSelected = false
        selectedModelId = model.id

        switch model.type {
        case .whisper(let url, _):
            AppPreferences.shared.selectedEngine = "whisper"
            let modelPath = modelManager.modelsDirectory.appendingPathComponent(url.lastPathComponent).path
            AppPreferences.shared.selectedWhisperModelPath = modelPath
        case .parakeet(let version):
            AppPreferences.shared.selectedEngine = "fluidaudio"
            AppPreferences.shared.fluidAudioModelVersion = version
        case .senseVoice:
            AppPreferences.shared.selectedEngine = "sensevoice"
        case .appleSpeech:
            AppPreferences.shared.selectedEngine = "apple"
        }
    }

    @MainActor
    func downloadModel(_ model: OnboardingUnifiedModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
            unifiedModels[index].downloadProgress = 0.0
        }
        
        switch model.type {
        case .whisper(let url, _):
            try await downloadWhisperModel(model: model, url: url)
        case .parakeet(let version):
            try await downloadParakeetModel(model: model, version: version)
        case .senseVoice:
            try await downloadSenseVoiceModel(model: model)
        case .appleSpeech:
            break
        }
    }
    
    @MainActor
    private func downloadWhisperModel(model: OnboardingUnifiedModel, url: URL) async throws {
        downloadTask = Task {
            do {
                let filename = url.lastPathComponent
                
                try await modelManager.downloadModel(url: url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.unifiedModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 0.0
                    }
                    selectModel(model)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    @MainActor
    private func downloadSenseVoiceModel(model: OnboardingUnifiedModel) async throws {
        downloadTask = Task {
            do {
                try await SenseVoiceModelManager.shared.download { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadProgress = progress
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = progress
                        }
                    }
                }
                try Task.checkCancellation()

                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 1.0
                    }
                    selectModel(model)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }

        try await downloadTask?.value
    }

    private func downloadParakeetModel(model: OnboardingUnifiedModel, version: String) async throws {
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let asrVersion = AsrModelVersion(preference: version)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                // Same progress as the Models pane: FluidAudio reports it, forward only.
                let models = try await AsrModels.downloadAndLoad(version: asrVersion) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        let value = max(self.downloadProgress, progress.fractionCompleted)
                        self.downloadProgress = value
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = value
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 1.0
                    }
                    selectModel(model)
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
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if !wasCancelled {
                throw error
            }
        }
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if let model = unifiedModels.first(where: { $0.name == modelName }) {
                if case .whisper(let url, _) = model.type {
                    let filename = url.lastPathComponent
                    modelManager.cancelDownload(name: filename)
                }
            }
            if let index = unifiedModels.firstIndex(where: { $0.name == modelName }) {
                unifiedModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
}

extension OnboardingViewModel {
    /// The model the model step recommends: the best one to download for the spoken language.
    /// Apple's, when offered, sits above it and is preselected, since it needs no download.
    var recommendedModel: OnboardingUnifiedModel? {
        unifiedModels.first { Self.isDefaultCandidate($0, language: selectedLanguage) }
    }

    var appleSpeechRow: OnboardingUnifiedModel? {
        unifiedModels.first(where: \.isAppleSpeech)
    }
}
