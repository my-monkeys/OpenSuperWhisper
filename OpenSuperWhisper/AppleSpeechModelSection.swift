import Speech
import SwiftUI
import WhisperCore

// SpeechTranscriber/AssetInventory and the full AppleSpeechSupport only exist in the
// macOS 26 SDK. `@available` guards the runtime, not compilation — so gate the whole
// file on the SDK (keyed off FoundationModels, a macOS-26-only framework), exactly like
// AppleSpeechEngine.swift. Without this, an older toolchain (CI's Xcode 16 runner) fails
// to compile it even though the call site is already #if-gated. No #else stub is needed:
// the only reference (Settings) is itself behind `#if canImport(FoundationModels)`.
#if canImport(FoundationModels)

/// Apple Speech section (Settings → Models when browsing the Apple engine, macOS 26+).
/// Works like every other engine's model list, with one row per language: Download
/// fetches its system assets (AssetInventory — shared across apps, updated with the
/// OS, nothing stored in the app), Select activates the Apple engine AND switches the
/// transcription language to that row (same mechanic as the ivrit.ai Hebrew model).
/// The active language wears the solid green check.
@available(macOS 26.0, *)
struct AppleSpeechModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var errorMessage: String?
    /// Every language the system model supports, with its resolved locale and asset status.
    @State private var languages: [LangAsset] = []
    @State private var installingCode: String?
    @State private var langProgress: Double = 0
    /// Regional variants of the active language (fr → fr_FR/fr_CH/fr_CA/fr_BE) and the
    /// one in effect. The picker only shows when there's an actual choice.
    @State private var variants: [Locale] = []
    @State private var selectedVariantID = ""

    private struct LangAsset: Identifiable {
        let code: String
        let localeID: String
        let name: String
        var installed: Bool
        var id: String { code }
    }

    var body: some View {
        SSection(title: "Languages") {
            if languages.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the system speech model…")
                        .font(.system(size: 11.5))
                        .foregroundColor(STheme.hint)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(languages) { lang in
                        languageRow(lang)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
            }

            if variants.count > 1 {
                SRow(title: "Regional variant",
                     hint: "Which regional model transcribes the selected language — spelling and numbers follow it.") {
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

            Text("The model is built into macOS: downloaded per language by the system, shared across apps, and updated with the OS — nothing is stored in the app. Selecting a language here also sets the transcription language. macOS keeps up to 5 languages reserved per app; beyond that the app rotates automatically.")
                .font(.system(size: 11))
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: viewModel.selectedLanguage) { await refresh() }
    }

    /// The language actually transcribing right now: Apple engine active + this row's
    /// language selected + assets present.
    private func isActive(_ lang: LangAsset) -> Bool {
        viewModel.selectedEngine == "apple"
            && lang.code == AppleSpeechSupport.effectiveLanguageCode(for: viewModel.selectedLanguage)
            && lang.installed
    }

    private func languageRow(_ lang: LangAsset) -> some View {
        let active = isActive(lang)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(lang.installed ? "Installed · on-device · managed by macOS"
                                    : "One-time system download")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if installingCode == lang.code {
                    ProgressView(value: langProgress)
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else if installingCode == lang.code {
                ProgressView().controlSize(.small)
            } else if lang.installed {
                Button("Select") { select(lang) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(active ? 0.7 : 0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if lang.installed && !active { select(lang) }
        }
    }

    /// Activate the Apple engine on this language — the language picker in Output and
    /// the menu bar follow, exactly like selecting any other engine's model.
    private func select(_ lang: LangAsset) {
        viewModel.selectedLanguage = lang.code
        viewModel.selectAppleSpeech()
    }

    private func refresh() async {
        let locale = await AppleSpeechSupport.resolveLocale(language: viewModel.selectedLanguage)
        variants = await AppleSpeechSupport.supportedVariants(for: viewModel.selectedLanguage)
        selectedVariantID = locale.identifier
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
            } catch {
                await MainActor.run {
                    installingCode = nil
                    errorMessage = "Couldn't download \(lang.name). Check your connection and try again."
                }
            }
        }
    }
}

#endif
