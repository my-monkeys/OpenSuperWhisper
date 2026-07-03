import Speech
import SwiftUI

/// Apple Speech row (Settings → Models when browsing the Apple engine, macOS 26+).
/// There is no app-side model file: macOS downloads per-language assets through
/// AssetInventory, shares them across apps and updates them with the OS. Clicking
/// installs the assets for the current transcription language if needed, then
/// activates the engine — same interaction as every other engine.
@available(macOS 26.0, *)
struct AppleSpeechModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var checked = false
    @State private var isInstalled = false
    @State private var isInstalling = false
    @State private var progress: Double = 0
    @State private var localeName = ""
    @State private var errorMessage: String?
    /// Regional variants of the current language (fr → fr_FR/fr_CH/fr_CA/fr_BE) and the
    /// one in effect. The picker only shows when there's an actual choice.
    @State private var variants: [Locale] = []
    @State private var selectedVariantID = ""
    /// Every language the system model supports, with its resolved locale and asset
    /// status — so any language can be preloaded from here, not just the current one.
    @State private var languages: [LangAsset] = []
    @State private var installingCode: String?
    @State private var langProgress: Double = 0

    private struct LangAsset: Identifiable {
        let code: String
        let localeID: String
        let name: String
        var installed: Bool
        var id: String { code }
    }

    var body: some View {
        SSection(title: "System speech model") {
            row
            if variants.count > 1 {
                SRow(title: "Regional variant",
                     hint: "Which regional model transcribes this language — spelling and numbers follow it.") {
                    Picker("", selection: $selectedVariantID) {
                        ForEach(variants, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: selectedVariantID) { _, newID in
                        guard !newID.isEmpty else { return }
                        let code = AppleSpeechSupport.effectiveLanguageCode(for: viewModel.selectedLanguage)
                        guard AppleSpeechSupport.localeOverrides[code] != newID else { return }
                        AppleSpeechSupport.localeOverrides[code] = newID
                        Task { await refresh() }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
            }
            Text("Built into macOS: the model is downloaded per language by the system, shared across apps, and updated with the OS — nothing is stored in the app. Change the transcription language in Output.")
                .font(.system(size: 11))
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)

            if !languages.isEmpty {
                SSection(title: "Languages") {
                    VStack(spacing: 0) {
                        ForEach(languages) { lang in
                            languageRow(lang)
                            if lang.id != languages.last?.id {
                                Rectangle().fill(STheme.border).frame(height: 1)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
                    Text("Preload any language's assets here; the language you dictate in is set in Output (or the menu bar).")
                        .font(.system(size: 11))
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: viewModel.selectedLanguage) { await refresh() }
    }

    private func languageRow(_ lang: LangAsset) -> some View {
        let isCurrent = lang.code == AppleSpeechSupport.effectiveLanguageCode(for: viewModel.selectedLanguage)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lang.name)
                    .font(.system(size: 12.5))
                    .foregroundColor(STheme.text)
                if installingCode == lang.code {
                    ProgressView(value: langProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 160, height: 5)
                        .padding(.top, 2)
                }
            }
            if isCurrent { STag("Current") }
            Spacer(minLength: 8)
            if lang.installed {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(STheme.ok)
            } else if installingCode == lang.code {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    installLanguage(lang)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(installingCode != nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var active: Bool { viewModel.selectedEngine == "apple" && isInstalled }

    private var row: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Speech")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isInstalling {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                        .padding(.top, 2)
                }
            }

            Spacer()

            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else if isInstalling || !checked {
                ProgressView().controlSize(.small)
            } else if isInstalled {
                Button("Select") { viewModel.selectAppleSpeech() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button(action: install) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(active ? 0.7 : 0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isInstalled && !active { viewModel.selectAppleSpeech() }
        }
    }

    private var subtitle: String {
        let lang = localeName.isEmpty ? "your language" : localeName
        if !checked { return "Checking \(lang) assets…" }
        return isInstalled
            ? "\(lang) · on-device · managed by macOS"
            : "\(lang) · one-time system download"
    }

    private func refresh() async {
        checked = false
        let locale = await AppleSpeechSupport.resolveLocale(language: viewModel.selectedLanguage)
        localeName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        variants = await AppleSpeechSupport.supportedVariants(for: viewModel.selectedLanguage)
        selectedVariantID = locale.identifier
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        isInstalled = (status == .installed)
        checked = true
        await AppleSpeechSupport.refreshCaches()
        await refreshLanguages()
    }

    /// One row per supported language, resolved to its effective locale (override or
    /// canonical) with the asset status. "mul" is the framework's multilingual pseudo
    /// entry — not a language anyone dictates in.
    private func refreshLanguages() async {
        var rows: [LangAsset] = []
        for code in AppleSpeechSupport.cachedSupportedLanguages where code != "mul" {
            let locale = await AppleSpeechSupport.resolveLocale(language: code)
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let status = await AssetInventory.status(forModules: [transcriber])
            rows.append(LangAsset(
                code: code,
                localeID: locale.identifier,
                name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                installed: status == .installed))
        }
        languages = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func installLanguage(_ lang: LangAsset) {
        errorMessage = nil
        installingCode = lang.code
        langProgress = 0
        Task {
            do {
                let locale = Locale(identifier: lang.localeID)
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                var poller: Task<Void, Never>?
                defer { poller?.cancel() }
                try await AppleSpeechSupport.installAssetsIfNeeded(
                    supporting: transcriber, locale: locale,
                    onProgress: { systemProgress in
                        poller?.cancel()
                        poller = Task {
                            while !Task.isCancelled {
                                let fraction = systemProgress.fractionCompleted
                                await MainActor.run { langProgress = fraction }
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                        }
                    })
                await MainActor.run {
                    if let i = languages.firstIndex(where: { $0.code == lang.code }) {
                        languages[i].installed = true
                    }
                    installingCode = nil
                }
                await refresh()
            } catch {
                await MainActor.run {
                    installingCode = nil
                    errorMessage = "Couldn't download \(lang.name). Check your connection and try again."
                }
            }
        }
    }

    private func install() {
        errorMessage = nil
        isInstalling = true
        progress = 0
        Task {
            do {
                let locale = await AppleSpeechSupport.resolveLocale(language: viewModel.selectedLanguage)
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                // The install reports through Foundation.Progress; poll it into
                // SwiftUI state for the linear bar.
                var poller: Task<Void, Never>?
                defer { poller?.cancel() }
                try await AppleSpeechSupport.installAssetsIfNeeded(
                    supporting: transcriber, locale: locale,
                    onProgress: { systemProgress in
                        poller?.cancel()
                        poller = Task {
                            while !Task.isCancelled {
                                let fraction = systemProgress.fractionCompleted
                                await MainActor.run { progress = fraction }
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                        }
                    })
                await MainActor.run {
                    isInstalled = true
                    isInstalling = false
                    viewModel.selectAppleSpeech()
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = "Couldn't download the speech assets. Check your connection and try again."
                }
            }
        }
    }
}
