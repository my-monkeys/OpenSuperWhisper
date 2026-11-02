import SwiftUI
import OpenSuperWhisperCore

/// Cleanup: hesitations, AI formatting, and the engine that runs it.
struct TextAICleanupGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// The stock pattern, as `AppPreferences` declares it. Kept here to tell a customised one apart.
    static let defaultFillerPattern = "\\b(um|uh|uh huh|er|ah|hmm|mm)\\b,?\\s*"

    /// One backend serves both this prose cleanup and the per-app formatting rules, so
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
                    SettingNotice("The engine below is used by the per-app formatting rules.")
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
            SettingRow("Default style", hint: "Chosen on the Style page.") {
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
        let apple = AppPreferences.shared.appleIntelligenceAvailability
        return SettingRow("AI engine", hint: backendHint) {
            SMenu(Text(backendLabel)) {
                Picker("", selection: $viewModel.aiBackend) {
                    Text("Built-in (Qwen)").tag("builtin")
                    Text("Ollama").tag("ollama")
                    Text("Server").tag("remote")
                    if apple == .available {
                        Text(TextAIAppleIntelligence.menuItem(apple)).tag("apple")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                // Listed even where it can't run, greyed with the reason, so a Mac that is one
                // setting away from it says which setting.
                if apple != .available {
                    Divider()
                    Button(TextAIAppleIntelligence.menuItem(apple)) {}
                        .disabled(true)
                }
            }
        }
    }

    private var backendLabel: LocalizedStringKey {
        switch viewModel.aiBackend {
        case "builtin": return "Built-in (Qwen)"
        case "remote": return "Server"
        case "apple": return "Apple Intelligence"
        default: return "Ollama"
        }
    }

    private var backendHint: LocalizedStringKey {
        switch viewModel.aiBackend {
        case "builtin": return "A Qwen2.5 model running on this Mac. The 1.5B is quick but can change the meaning of a sentence; the 7B is more careful and uses about 4 GB of memory."
        case "remote": return "Any OpenAI-compatible server."
        case "apple": return "Apple's on-device model, built into macOS. The most careful one: it fixes grammar without adding or dropping words."
        default: return "Your local Ollama server."
        }
    }
}
