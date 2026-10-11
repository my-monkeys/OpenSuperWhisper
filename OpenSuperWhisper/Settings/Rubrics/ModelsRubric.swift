import SwiftUI
import AppKit
import FluidAudio
import OpenSuperWhisperCore

/// Settings → Models: one card per engine, then the chosen engine's models and settings.
///
/// Clicking a card only browses that engine. The active engine changes when a model is used,
/// so looking at Whisper's list never switches dictation off Parakeet. The engine-level
/// reloads (model loading when the engine or model changes) live in `AppShellView`.
struct ModelsRubric: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var selection = ModelSelectionStore.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var browseEngine = AppPreferences.shared.selectedEngine

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "Engine", rubric: .models,
              keywords: "parakeet whisper sensevoice apple speech server remote moteur serveur"),
        .init(title: "Service", rubric: .models,
              keywords: "preset groq server remote serveur préréglage"),
        .init(title: "Server URL", rubric: .models,
              keywords: "address endpoint url adresse serveur groq"),
        .init(title: "API key", rubric: .models,
              keywords: "token key keychain clé api trousseau groq"),
        .init(title: "Connection", rubric: .models,
              keywords: "test connection reachable tester connexion joignable"),
        .init(title: "Request timeout", rubric: .models,
              keywords: "timeout delay délai maximum serveur"),
        .init(title: "Local fallback", rubric: .models,
              keywords: "offline fallback network secours hors ligne réseau modèle local"),
        .init(title: "Free memory when idle", rubric: .models, advanced: true,
              keywords: "unload memory ram idle libérer mémoire décharger"),
        .init(title: "Models folder", rubric: .models, advanced: true,
              keywords: "folder directory finder storage dossier modèles stockage télécharger"),
        .init(title: "Show all variants", rubric: .models, advanced: true,
              keywords: "variants quantized q5 q8 ivrit variantes"),
        .init(title: "Import a model", rubric: .models, advanced: true,
              keywords: "import bin core ml importer modèle fichier"),
    ]

    var body: some View {
        RubricPage(.models, intro: "The model that turns your voice into text. Everything runs on this Mac unless you pick a server.") {
            engineSection
            engineContent
            onThisMacGroup
            perAppLink
        }
        .onAppear { browseEngineForSearch(navigation.settingsFocusRow) }
        .onChange(of: navigation.settingsFocusRow) { _, row in browseEngineForSearch(row) }
    }

    /// A search hit on a row that only one engine shows opens that engine's card first, or the
    /// page would have nothing to scroll to.
    private func browseEngineForSearch(_ row: String?) {
        guard let row else { return }
        if ["Service", "Server URL", "API key", "Connection", "Request timeout", "Local fallback"].contains(row) {
            browseEngine = "remote"
        } else if ["Show all variants", "Import a model"].contains(row) {
            browseEngine = "whisper"
        } else if row == "Models folder", modelsFolder == nil {
            browseEngine = "whisper"
        }
    }

    // MARK: - Engines

    private struct Engine: Identifiable {
        let tag: String
        let name: LocalizedStringKey
        let blurb: LocalizedStringKey
        var id: String { tag }
    }

    private var engines: [Engine] {
        var list = [
            Engine(tag: "fluidaudio", name: "Parakeet", blurb: "Fast, on this Mac"),
            Engine(tag: "whisper", name: "Whisper", blurb: "Accurate · 99 languages"),
        ]
        #if arch(arm64)
        list.append(Engine(tag: "sensevoice", name: "SenseVoice", blurb: "zh · yue · ja · ko"))
        #endif
        if AppleSpeechSupport.isSupported {
            list.append(Engine(tag: "apple", name: "Apple", blurb: "Built into macOS"))
        }
        list.append(Engine(tag: "remote", name: "Server", blurb: "Your own server"))
        return list
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Engine")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Spacer(minLength: 0)
                activePill
            }
            .id("Engine")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(engines) { engine in
                    engineCard(engine)
                }
            }
        }
    }

    private func engineCard(_ engine: Engine) -> some View {
        let browsed = browseEngine == engine.tag
        return Button { browseEngine = engine.tag } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.name)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(browsed ? STheme.accent : STheme.textBright)
                    .lineLimit(1)
                Text(engine.blurb)
                    .scaledFont(size: 12.5)
                    .foregroundColor(STheme.hint)
                    // Two lines reserved on every card, so a blurb that wraps doesn't make its
                    // card taller than the others in the row.
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(browsed ? STheme.accentTint : STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(browsed ? STheme.accent : STheme.border, lineWidth: browsed ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(browsed ? .isSelected : [])
    }

    /// "● Active · Parakeet v3": what transcribes, whichever engine is being browsed.
    @ViewBuilder private var activePill: some View {
        if let active = selection.active {
            HStack(spacing: 6) {
                Circle().fill(STheme.readyDot).frame(width: 7, height: 7)
                Text("Active · \(activeName(active))")
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundColor(STheme.ok)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(STheme.okBg))
            .frame(maxWidth: 300, alignment: .trailing)
        }
    }

    private func activeName(_ option: DictationModelOption) -> String {
        switch option.engine {
        case "fluidaudio":
            return SettingsFluidAudioModels.availableModels.first { $0.version == option.identifier }?.name
                ?? "Parakeet \(option.identifier)"
        case "whisper":
            let file = URL(fileURLWithPath: option.identifier).lastPathComponent
            return SettingsDownloadableModels.availableModels.first { $0.filename == file }.map { "Whisper \($0.name)" }
                ?? option.displayName
        case "remote":
            return option.displayName
        default:
            return option.displayName
        }
    }

    // MARK: - Engine content

    @ViewBuilder private var engineContent: some View {
        switch browseEngine {
        case "whisper":
            SettingsGroup("Model") {
                ForEach($viewModel.downloadableModels) { $model in
                    WhisperModelRow(model: $model, viewModel: viewModel)
                }
                SettingRow("Show all variants", hint: "q5, q8, in-between sizes and other community models.",
                           advanced: true, soon: true) {
                    SSwitch(isOn: .constant(false))
                }
                SettingRow("Import a model", hint: "A .bin file or a Core ML folder.", advanced: true, soon: true) {
                    Button("Choose…") {}
                        .buttonStyle(.sSecondary)
                }
            }
        case "fluidaudio":
            SettingsGroup("Model") {
                ForEach($viewModel.downloadableFluidAudioModels) { $model in
                    ParakeetModelRow(model: $model, viewModel: viewModel)
                }
            }
        case "sensevoice":
            #if arch(arm64)
            SenseVoiceModelSection(viewModel: viewModel)
            #else
            EmptyView()
            #endif
        case "apple":
            appleSection
        case "remote":
            RemoteSettingsSection(viewModel: viewModel)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var appleSection: some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            AppleSpeechModelSection(viewModel: viewModel)
        }
        #endif
    }

    // MARK: - On this Mac

    /// Where the browsed engine keeps its files. SenseVoice and Apple have nothing to show:
    /// SenseVoice is a single fixed model, Apple's assets belong to macOS.
    private var modelsFolder: URL? {
        switch browseEngine {
        case "whisper": return WhisperModelManager.shared.modelsDirectory
        case "fluidaudio": return AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        default: return nil
        }
    }

    @ViewBuilder private var onThisMacGroup: some View {
        if browseEngine != "remote" {
            SettingsGroup("On this Mac", advanced: true) {
                SettingRow("Free memory when idle",
                           hint: "Unloads the Whisper model (about 1 GB) between dictations and reloads it when you dictate. Saves memory, adds a little delay at the start.",
                           badge: ("Whisper", .engine), advanced: true) {
                    SSwitch(isOn: $viewModel.unloadWhisperModelWhenIdle)
                }
                if let folder = modelsFolder {
                    SettingRow("Models folder",
                               hint: "\((folder.path as NSString).abbreviatingWithTildeInPath)",
                               advanced: true) {
                        HStack(spacing: 8) {
                            Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                                .buttonStyle(.sSecondary)
                            Button {} label: {
                                HStack(spacing: 6) {
                                    Text("Clean up")
                                    SoonBadge()
                                }
                            }
                            .buttonStyle(.sDanger)
                            .disabled(true)
                        }
                    }
                }
            }
        }
    }

    private var perAppLink: some View {
        Button {
            navigation.closeSettings()
            navigation.go(.style)
        } label: {
            HStack(spacing: 4) {
                Text("Change the model per app in Style → Per app")
                Image(systemName: "arrow.right")
                    .scaledFont(size: 11, weight: .semibold)
            }
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
    }
}
