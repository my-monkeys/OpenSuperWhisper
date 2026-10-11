import Foundation
import SwiftUI
import FluidAudio
import OpenSuperWhisperCore

enum OnboardingShortcutOption: String, CaseIterable {
    case keyCombination
    case rightOption
}

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            suggestDefaultModel()
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var selectedShortcut: OnboardingShortcutOption {
        didSet {
            switch selectedShortcut {
            case .keyCombination:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            case .rightOption:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
            }
            AppPreferences.shared.setRightOptionTrigger(selectedShortcut == .rightOption)
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var unifiedModels: [OnboardingUnifiedModel] = []
    @Published var selectedModelId: UUID?
    @Published var remoteSelected: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?

    private let modelManager = WhisperModelManager.shared
    private var downloadTask: Task<Void, Error>?

    init() {
        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        
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
        
        initializeUnifiedModels()
    }

    func initializeUnifiedModels() {
        unifiedModels = OnboardingUnifiedModels.availableModels.map { model in
            var updatedModel = model
            switch model.type {
            case .whisper(let url, _):
                let filename = url.lastPathComponent
                updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            case .parakeet(let version):
                updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: version)
            case .senseVoice:
                updatedModel.isDownloaded = SenseVoiceModelManager.shared.isDownloaded
            }
            return updatedModel
        }
        
        if selectedModelId == nil, let firstDownloaded = unifiedModels.first(where: { $0.isDownloaded }) {
            selectedModelId = firstDownloaded.id
        }
        suggestDefaultModel()
    }

    /// With nothing downloaded yet, preselects Parakeet Ultra, or Whisper when Ultra does not
    /// speak the chosen language. Follows the language picker until a model is on disk; a model
    /// the user already has is never second-guessed.
    private func suggestDefaultModel() {
        guard !remoteSelected, !unifiedModels.contains(where: { $0.isDownloaded }) else { return }
        guard let model = unifiedModels.first(where: { Self.isDefaultCandidate($0, language: selectedLanguage) })
        else { return }
        selectModel(model)
    }

    static func isDefaultCandidate(_ model: OnboardingUnifiedModel, language: String) -> Bool {
        switch model.type {
        case .parakeet(let version):
            return language == "auto" || EngineCapabilities.supportedLanguages(
                engine: "fluidaudio", fluidAudioModelVersion: version).contains(language)
        case .whisper:
            return true
        case .senseVoice:
            return false
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion = AsrModelVersion(preference: version)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    var canContinue: Bool {
        if remoteSelected { return true }
        guard let selectedId = selectedModelId else { return false }
        return unifiedModels.contains { $0.id == selectedId && $0.isDownloaded }
    }

    // Selecting a remote (OpenAI-compatible) server skips the local-model
    // requirement entirely; the endpoint/key are configured later in Settings.
    func selectRemote() {
        remoteSelected = true
        selectedModelId = nil
        AppPreferences.shared.selectedEngine = "remote"
    }

    func selectModel(_ model: OnboardingUnifiedModel) {
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
    /// The model the model step puts first: the one `suggestDefaultModel` picks for the spoken
    /// language when nothing is on disk yet.
    var recommendedModel: OnboardingUnifiedModel? {
        unifiedModels.first { Self.isDefaultCandidate($0, language: selectedLanguage) }
    }

    var hasDownloadedModel: Bool {
        unifiedModels.contains { $0.isDownloaded }
    }
}
