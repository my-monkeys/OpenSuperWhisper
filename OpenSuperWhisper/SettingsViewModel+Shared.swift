import Combine
import Foundation
import OpenSuperWhisperCore

extension SettingsViewModel {
    /// The one the app runs on: the Settings window edits it and the dashboard's pages read it.
    /// Tests and snapshots build their own, fresh from the preferences they just set.
    static let shared: SettingsViewModel = {
        let model = SettingsViewModel()
        model.reloadTranscriptionWhenTheModelChanges()
        return model
    }()

    private static var subscriptions = Set<AnyCancellable>()

    /// A model picked in Settings has to reach the transcription service whichever window is
    /// open: these lived on the dashboard's view and did nothing once Settings could be changed
    /// with the dashboard closed.
    private func reloadTranscriptionWhenTheModelChanges() {
        $selectedEngine.dropFirst().sink { [weak self] engine in
            guard engine == "fluidaudio" else { return }
            DispatchQueue.main.async { self?.initializeFluidAudioModels() }
        }.store(in: &Self.subscriptions)
        $fluidAudioModelVersion.dropFirst().sink { _ in
            Task { @MainActor in TranscriptionService.shared.reloadEngine() }
        }.store(in: &Self.subscriptions)
        $selectedModelURL.dropFirst().sink { [weak self] url in
            guard self?.selectedEngine == "whisper", let path = url?.path else { return }
            Task { @MainActor in TranscriptionService.shared.reloadModel(with: path) }
        }.store(in: &Self.subscriptions)
    }
}
