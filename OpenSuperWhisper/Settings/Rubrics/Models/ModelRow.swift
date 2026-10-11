import SwiftUI
import OpenSuperWhisperCore

/// Where a downloadable model stands, which decides the button its row shows.
enum ModelRowState: Equatable {
    case notDownloaded
    /// `progress` is nil until the first byte gives a percentage.
    case downloading(progress: Double?, cancellable: Bool)
    case downloaded
    /// The model that transcribes right now. Only one row on the page is ever in this state.
    case active
}

/// One model in an engine's Model group, drawn like a `SettingRow`: name and details on the
/// left, a progress bar under them while downloading, and one button on the right
/// ("✓ Active", "Use", "Download · 460 MB" or "Cancel"). A click on a downloaded row uses it.
struct ModelRow: View {
    let name: String
    let detail: String
    let size: String?
    let state: ModelRowState
    var downloadDisabled = false
    let onUse: () -> Void
    let onDownload: () -> Void
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                progressBar
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            action
        }
        .modelRowFrame()
        .contentShape(Rectangle())
        .onTapGesture { if state == .downloaded { onUse() } }
    }

    @ViewBuilder private var progressBar: some View {
        if case .downloading(let progress, _) = state {
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(STheme.accent)
            .frame(maxWidth: 260)
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .active:
            ActiveModelBadge()
        case .downloaded:
            Button("Use", action: onUse)
                .buttonStyle(.sSecondary)
        case .downloading(_, let cancellable):
            if cancellable {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .notDownloaded:
            Button(action: onDownload) {
                if let size {
                    Text("Download · \(size)")
                } else {
                    Text("Download")
                }
            }
            .buttonStyle(.sSecondary)
            .disabled(downloadDisabled)
        }
    }
}

/// The green "✓ Active" of the model in use. A status, not a button: it has nothing to do.
struct ActiveModelBadge: View {
    var body: some View {
        Button {} label: { Text("✓ Active") }
            .buttonStyle(.sOK)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRemoveTraits(.isButton)
    }
}

extension View {
    /// The padding, height and top hairline of a row inside a `SettingsGroup`, for rows that
    /// need more than `SettingRow` offers (a progress bar, a list).
    func modelRowFrame() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(STheme.border).frame(height: 1)
            }
    }
}

// MARK: - Catalog rows

/// A Whisper model from the download catalog, with the logic of the old `ModelDownloadItemView`.
struct WhisperModelRow: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var errorMessage: String?

    private var isActive: Bool {
        viewModel.selectedEngine == "whisper"
            && viewModel.selectedModelURL?.lastPathComponent == model.filename
    }

    private var isDownloadingThis: Bool {
        viewModel.isDownloading && viewModel.downloadingModelName == model.name
    }

    private var state: ModelRowState {
        if isDownloadingThis || (model.downloadProgress > 0 && model.downloadProgress < 1) {
            let progress = model.downloadProgress > 0 && model.downloadProgress < 1 ? model.downloadProgress : nil
            return .downloading(progress: progress, cancellable: isDownloadingThis)
        }
        if model.isDownloaded { return isActive ? .active : .downloaded }
        return .notDownloaded
    }

    var body: some View {
        ModelRow(name: model.name, detail: "\(model.description) · \(model.sizeString)",
                 size: model.sizeString, state: state,
                 downloadDisabled: viewModel.isDownloading,
                 onUse: use, onDownload: download, onCancel: viewModel.cancelDownload)
            .modelDownloadAlert($errorMessage)
    }

    private func use() {
        let path = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
        viewModel.selectModel(URL(fileURLWithPath: path))
    }

    private func download() {
        Task {
            do {
                try await viewModel.downloadModel(model)
            } catch is CancellationError {
                // Cancelled from the row: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A Parakeet model, with the logic of the old `FluidAudioModelDownloadItemView`.
struct ParakeetModelRow: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var errorMessage: String?

    private var isActive: Bool {
        viewModel.selectedEngine == "fluidaudio" && viewModel.fluidAudioModelVersion == model.version
    }

    private var isDownloadingThis: Bool {
        viewModel.isDownloading && viewModel.downloadingModelName == model.name
    }

    private var state: ModelRowState {
        if isDownloadingThis {
            let progress = model.downloadProgress > 0 && model.downloadProgress < 1 ? model.downloadProgress : nil
            return .downloading(progress: progress, cancellable: true)
        }
        if model.isDownloaded { return isActive ? .active : .downloaded }
        return .notDownloaded
    }

    var body: some View {
        ModelRow(name: model.name, detail: "\(model.description) · \(model.sizeString)",
                 size: model.sizeString, state: state,
                 downloadDisabled: viewModel.isDownloading,
                 onUse: { viewModel.selectParakeet(model.version) },
                 onDownload: download, onCancel: viewModel.cancelDownload)
            .modelDownloadAlert($errorMessage)
    }

    private func download() {
        Task {
            do {
                try await viewModel.downloadFluidAudioModel(model)
            } catch is CancellationError {
                // Cancelled from the row: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension View {
    func modelDownloadAlert(_ message: Binding<String?>) -> some View {
        alert("Download Error", isPresented: Binding(get: { message.wrappedValue != nil },
                                                     set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: message.wrappedValue ?? "")
        }
    }
}
