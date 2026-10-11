import SwiftUI
import OpenSuperWhisperCore

/// The fields of the chosen AI engine: the built-in model and its download, Ollama's model and
/// endpoint, or the remote server. Then the connection status for the two that have a server.
struct TextAIBackendFields: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        switch viewModel.aiBackend {
        case "builtin":
            builtInFields
        case "remote":
            RemoteCleanupSettingsView(viewModel: viewModel)
            statusLine
        default:
            ollamaFields
            statusLine
        }
    }

    // MARK: Built-in

    @ViewBuilder private var builtInFields: some View {
        SettingRow("Qwen model", hint: "The bigger model follows instructions far more reliably; the smaller one is quicker and lighter.",
                   advanced: true, indented: true) {
            SMenu(Text(verbatim: shortModelName)) {
                Picker("", selection: $viewModel.builtInModelFileName) {
                    ForEach(LLMModelManager.availableModels, id: \.fileName) { model in
                        Text(model.displayName).tag(model.fileName)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        if viewModel.builtInModelDownloaded {
            TextAILine(indented: true) {
                TextAIOKPill("✓ Model ready, runs on this Mac")
                TextAIFootnote("Loads on first use (a few seconds), then frees its memory after 5 minutes idle.")
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Button("Delete") { viewModel.deleteBuiltInModel() }
                    .buttonStyle(.sDanger)
            }
        } else if let progress = viewModel.builtInModelDownloadProgress {
            TextAILine(indented: true) {
                ProgressView(value: progress)
                    .tint(STheme.accent)
                    .frame(maxWidth: 220)
                Text(verbatim: "\(Int(progress * 100))%")
                    .scaledFont(size: 13, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor(STheme.textSecondary)
            }
        } else {
            TextAILine(indented: true) {
                TextAIFootnote("Apache-2.0. One-time download, no server needed.")
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Button("Download model (\(viewModel.builtInModelSizeText))") {
                    viewModel.downloadBuiltInModel()
                }
                .buttonStyle(.sPrimary)
            }
        }
        if let error = viewModel.builtInModelDownloadError {
            TextAILine(indented: true) {
                TextAIFootnote("✕ \(error)", color: STheme.danger)
            }
        }
    }

    /// "Qwen2.5 7B" rather than the full "Qwen2.5 7B Instruct (Q3_K_M)", which left the hint
    /// beside it a few words per line at the narrowest window. The menu lists the full names.
    private var shortModelName: String {
        let name = LLMModelManager.model(fileName: viewModel.builtInModelFileName).displayName
        return name.components(separatedBy: " Instruct").first ?? name
    }

    // MARK: Ollama

    @ViewBuilder private var ollamaFields: some View {
        SettingRow("Ollama model", advanced: true, indented: true) {
            STextField("llama3.2", text: $viewModel.aiOllamaModel, monospaced: true, width: 200)
        }
        SettingRow("Endpoint", advanced: true, indented: true) {
            HStack(spacing: 8) {
                Button("Test") { viewModel.testLLMConnection() }
                    .buttonStyle(.sSecondary)
                STextField("http://localhost:11434", text: $viewModel.aiOllamaEndpoint,
                           monospaced: true, width: 220)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusLine: some View {
        if viewModel.llmStatus != .unknown {
            TextAILine(indented: true) { statusContent }
        }
    }

    @ViewBuilder private var statusContent: some View {
        let isRemote = viewModel.aiBackend == "remote"
        switch viewModel.llmStatus {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            TextAIFootnote("Checking the connection…")
        case .ok:
            TextAIOKPill("✓ Connected, model ready")
        case .modelMissing(let model):
            TextAIFootnote(isRemote
                           ? "Reachable, but “\(model)” isn't in the server's model list"
                           : "Reachable, but “\(model)” isn't pulled. Run: ollama pull \(model)",
                           color: STheme.warn)
        case .authFailed:
            TextAIFootnote("✕ The server rejected the API key", color: STheme.danger)
        case .unreachable:
            TextAIFootnote(isRemote
                           ? "✕ Can't reach the server. Check the URL."
                           : "✕ Can't reach Ollama. Is it running? (ollama serve)",
                           color: STheme.danger)
        }
    }
}
