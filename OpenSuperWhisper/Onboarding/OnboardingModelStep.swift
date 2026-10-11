import SwiftUI
import OpenSuperWhisperCore

/// Step 2: the spoken language, then the model the app suggests for it, explained, with the
/// other models and a remote server below. Continue waits for a model on disk (or a server).
struct OnboardingModelStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsGroup("Spoken language") {
                SettingRow("I speak", hint: "The recommendation follows your language.") {
                    languageMenu
                }
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    SettingRow("Asian autocorrect", hint: "Fixes spacing in Chinese, Japanese and Korean text.") {
                        SSwitch(isOn: $viewModel.useAsianAutocorrect)
                    }
                }
            }

            if let recommended = binding(for: viewModel.recommendedModel) {
                OnboardingModelRow(model: recommended, viewModel: viewModel,
                                   explanation: explanation(for: recommended.wrappedValue))
            }

            section("Other options") {
                ForEach($viewModel.unifiedModels) { $model in
                    if model.id != viewModel.recommendedModel?.id {
                        OnboardingModelRow(model: $model, viewModel: viewModel)
                    }
                }
                remoteOption
            }
        }
    }

    private var languageMenu: some View {
        SMenu(Text(LanguageUtil.languageNames[viewModel.selectedLanguage] ?? viewModel.selectedLanguage)) {
            Picker("", selection: $viewModel.selectedLanguage) {
                ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                    Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(STheme.textBright)
            content()
        }
    }

    private func binding(for model: OnboardingUnifiedModel?) -> Binding<OnboardingUnifiedModel>? {
        guard let model, let index = viewModel.unifiedModels.firstIndex(where: { $0.id == model.id })
        else { return nil }
        return $viewModel.unifiedModels[index]
    }

    private func explanation(for model: OnboardingUnifiedModel) -> LocalizedStringKey {
        switch model.type {
        case .parakeet:
            return "Fast and accurate in your language. Runs on this Mac, no account needed."
        case .whisper, .senseVoice:
            return "Understands your language well. Runs on this Mac, no account needed."
        }
    }

    // A remote (OpenAI-compatible) server needs no local model; its endpoint and key are set
    // in Settings once setup is done.
    private var remoteOption: some View {
        Button { viewModel.selectRemote() } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "cloud")
                    .scaledFont(size: 18)
                    .foregroundColor(STheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use a remote server")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text("OpenAI-compatible API (Groq, or your own server). Set the endpoint and key in Settings after setup.")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if viewModel.remoteSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(STheme.accent)
                }
            }
            .onboardingChoice(selected: viewModel.remoteSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.remoteSelected ? .isSelected : [])
    }
}

/// One model: what it is, its download and its state. `explanation` marks the recommended one,
/// drawn larger with the reason it is suggested.
struct OnboardingModelRow: View {
    @Binding var model: OnboardingUnifiedModel
    @ObservedObject var viewModel: OnboardingViewModel
    var explanation: LocalizedStringKey? = nil
    @State private var showError = false
    @State private var errorMessage = ""

    private var isSelected: Bool { viewModel.selectedModelId == model.id }
    private var isDownloadingThis: Bool {
        viewModel.isDownloading && viewModel.downloadingModelName == model.name
    }
    private var prominent: Bool { explanation != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if prominent {
                    SBadge("Recommended", kind: .new).padding(.bottom, 4)
                }
                HStack(spacing: 8) {
                    Text(model.name)
                        .scaledFont(size: prominent ? 20 : 15, weight: prominent ? .bold : .semibold)
                        .foregroundColor(STheme.textBright)
                    if model.isDownloaded {
                        SBadge("Downloaded", kind: .engine)
                    }
                }
                Text(model.description)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation {
                    Text(explanation)
                        .scaledFont(size: 14)
                        .foregroundColor(STheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                progress
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            action
        }
        .onboardingChoice(selected: isSelected, padding: prominent ? 20 : 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected { viewModel.selectModel(model) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// A bar once the download reports how far it is, a spinner before that (Parakeet's first
    /// moments, and loading it once fetched).
    @ViewBuilder private var progress: some View {
        if model.downloadProgress > 0 && model.downloadProgress < 1 {
            ProgressView(value: model.downloadProgress)
                .progressViewStyle(.linear)
                .tint(STheme.accent)
                .frame(maxWidth: 280)
                .padding(.top, 6)
        } else if isDownloadingThis {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 6)
        }
    }

    @ViewBuilder private var action: some View {
        if isDownloadingThis {
            Button("Cancel") { viewModel.cancelDownload() }
                .buttonStyle(.sSecondary)
        } else if model.isDownloaded {
            if isSelected {
                Label("Selected", systemImage: "checkmark")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.ok)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.okBg))
                    .fixedSize()
            } else {
                Button("Select") { viewModel.selectModel(model) }
                    .buttonStyle(.sSecondary)
            }
        } else {
            Button {
                download()
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SButtonStyle(kind: prominent ? .primary : .secondary))
            .disabled(viewModel.isDownloading)
        }
    }

    private func download() {
        Task {
            do {
                try await viewModel.downloadModel(model)
            } catch is CancellationError {
                // Cancelled by the user: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

extension View {
    /// The card every onboarding choice sits on: cream with a hairline, accent ring once chosen.
    func onboardingChoice(selected: Bool, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? STheme.accentTint : STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
    }
}
