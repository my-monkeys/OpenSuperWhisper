import SwiftUI
import OpenSuperWhisperCore

/// SenseVoice's Model group (Settings → Models when browsing SenseVoice). One model: Download
/// fetches it and then uses it, Use activates SenseVoice once it is on disk.
struct SenseVoiceModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var isDownloaded = SenseVoiceModelManager.shared.isDownloaded
    @State private var downloadFailed = false

    private var state: ModelRowState {
        if isDownloading { return .downloading(progress: progress > 0 ? progress : nil, cancellable: false) }
        guard isDownloaded else { return .notDownloaded }
        return viewModel.selectedEngine == "sensevoice" ? .active : .downloaded
    }

    var body: some View {
        SettingsGroup("Model") {
            ModelRow(name: "SenseVoice Small",
                     detail: String(localized: "Chinese, Cantonese, English, Japanese, Korean · Apple Silicon"),
                     size: SenseVoiceModelManager.shared.downloadSizeString,
                     state: state,
                     onUse: select, onDownload: select)
            if downloadFailed {
                SettingNotice("Download failed. Check your connection and try again.")
            }
        }
    }

    private func select() {
        guard !isDownloading else { return }
        downloadFailed = false
        if isDownloaded {
            viewModel.selectSenseVoice()
            return
        }
        isDownloading = true
        progress = 0
        Task {
            do {
                try await SenseVoiceModelManager.shared.download { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run {
                    isDownloaded = true
                    isDownloading = false
                    viewModel.selectSenseVoice()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadFailed = true
                }
            }
        }
    }
}
