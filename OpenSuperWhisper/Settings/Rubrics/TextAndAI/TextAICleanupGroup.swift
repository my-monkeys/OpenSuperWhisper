import SwiftUI
import OpenSuperWhisperCore

/// Cleanup: hesitations, AI formatting, and the engine that runs it.
struct TextAICleanupGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// The stock pattern, as `AppPreferences` declares it. Kept here to tell a customised one apart.
    static let defaultFillerPattern = "\\b(um|uh|uh huh|er|ah|hmm|mm)\\b,?\\s*"

    /// One backend serves both this prose cleanup and the per-app formatting rules in Style, so
    /// its fields stay visible while either is on: someone using formatting only would otherwise
    /// have nowhere to pick a backend or download a model.
    private var showsEngine: Bool {
        viewModel.aiPostProcessingEnabled || viewModel.appContextFormattingEnabled
    }

    var body: some View {
        SettingsGroup("Cleanup") {
            hesitationRows
            SettingRow("Automatic spaces and capitals",
                       hint: "Between two sentences and at the start of a dictation.", soon: true) {
                SSwitch(isOn: .constant(false))
            }
            SettingRow("Format with AI",
                       hint: "Cleans up the text with a language model before inserting it.") {
                SSwitch(isOn: $viewModel.aiPostProcessingEnabled)
            }
            if showsEngine {
                if !viewModel.aiPostProcessingEnabled {
                    SettingNotice("The engine below is used by the per-app formatting rules in Style.")
                }
                engineRow
                TextAIBackendFields(viewModel: viewModel)
                TextAIInstructions(viewModel: viewModel)
                SettingRow("If the AI fails, paste the raw text",
                           hint: "If the model errors or returns nothing usable, the transcription is inserted as it is.",
                           advanced: true) {
                    Text("Always on")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(STheme.hint)
                }
            }
            SettingRow("Default style", hint: "Will be chosen on the Style page.", badge: ("Soon", .soon)) {
                Button("Style →") {
                    AppNavigation.shared.closeSettings()
                    AppNavigation.shared.go(.style)
                }
                .buttonStyle(.sSecondary)
            }
        }
    }

    // MARK: Hesitations

    @ViewBuilder private var hesitationRows: some View {
        SettingRow("Remove hesitations", hint: "Strips um, uh, er… before inserting.") {
            SSwitch(isOn: $viewModel.removeFillerWords)
        }
        if viewModel.removeFillerWords {
            let customized = viewModel.fillerWordsPattern != Self.defaultFillerPattern
            SettingRow("Custom hesitations",
                       hint: "A case-insensitive regular expression, applied before pasting.",
                       badge: customized ? ("Customized", .custom) : nil,
                       advanced: true, stacked: true) {
                VStack(alignment: .leading, spacing: 8) {
                    TextAIEditor(text: $viewModel.fillerWordsPattern, monospaced: true, height: 52)
                    if customized {
                        Button("Reset to default") { viewModel.fillerWordsPattern = Self.defaultFillerPattern }
                            .buttonStyle(.sDanger)
                    }
                }
            }
        }
    }

    // MARK: Engine

    private var engineRow: some View {
        SettingRow("AI engine", hint: backendHint) {
            SMenu(Text(backendLabel)) {
                Picker("", selection: $viewModel.aiBackend) {
                    Text("Built-in (Qwen)").tag("builtin")
                    Text("Ollama").tag("ollama")
                    Text("Server").tag("remote")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                // #158: shown so the choice is known to be coming, never selectable.
                Button("Apple Intelligence (soon)") {}
                    .disabled(true)
            }
        }
    }

    private var backendLabel: LocalizedStringKey {
        switch viewModel.aiBackend {
        case "builtin": return "Built-in (Qwen)"
        case "remote": return "Server"
        default: return "Ollama"
        }
    }

    private var backendHint: LocalizedStringKey {
        switch viewModel.aiBackend {
        case "builtin": return "A Qwen2.5 model running on this Mac."
        case "remote": return "Any OpenAI-compatible server."
        default: return "Your local Ollama server."
        }
    }
}
