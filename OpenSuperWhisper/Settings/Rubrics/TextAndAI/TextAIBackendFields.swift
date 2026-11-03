import SwiftUI
import OpenSuperWhisperCore

/// The fields of the chosen AI engine: the built-in model and its download, Ollama's model and
/// endpoint, the remote server, or whether Apple Intelligence can run. Then the connection status
/// for the two that have a server.
struct TextAIBackendFields: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var session = CleanupSessionStatus.shared

    var body: some View {
        switch viewModel.aiBackend {
        case "builtin":
            builtInFields
        case "apple":
            appleFields
        case "remote":
            RemoteCleanupSettingsView(viewModel: viewModel)
            statusLine
        default:
            ollamaFields
            statusLine
        }
        lastFailureLine
    }

    // MARK: Last failure

    /// The connection test passing says little about a cleanup that is failing, so the failure
    /// the last dictation hit is shown on its own until a pass works again (#264).
    @ViewBuilder private var lastFailureLine: some View {
        if let failure = session.lastFailure {
            TextAILine(indented: true) {
                Text("✕ The last cleanup failed: \(failure.reason)")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(failure.date, format: .relative(presentation: .named))
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
            }
            .help(failure.model)
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
                TextAIFootnote(viewModel.unloadBuiltInModelWhenIdle
                               ? "Loads on first use (a few seconds), then frees its memory after 5 minutes idle."
                               : "Loaded at launch and kept in memory.")
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
        SettingRow("Free memory when idle",
                   hint: "Unloads the Qwen model (about 1 GB, or 4 GB for the 7B model) after 5 minutes without a dictation and reloads it when you dictate. Saves memory, but the first cleanup after a break takes a few seconds longer.",
                   badge: ("Qwen", .engine), advanced: true, indented: true) {
            SSwitch(isOn: $viewModel.unloadBuiltInModelWhenIdle)
        }
    }

    /// "Qwen2.5 7B" rather than the full "Qwen2.5 7B Instruct (Q3_K_M)", which left the hint
    /// beside it a few words per line at the narrowest window. The menu lists the full names.
    private var shortModelName: String {
        let name = LLMModelManager.model(fileName: viewModel.builtInModelFileName).displayName
        return name.components(separatedBy: " Instruct").first ?? name
    }

    // MARK: Apple Intelligence

    @ViewBuilder private var appleFields: some View {
        let availability = AppPreferences.shared.appleIntelligenceAvailability
        if let notice = TextAIAppleIntelligence.unavailableNotice(availability) {
            TextAILine(indented: true) {
                TextAIFootnote(notice, color: STheme.warn)
            }
        } else {
            TextAILine(indented: true) {
                TextAIOKPill("✓ Ready, runs on this Mac")
                TextAIFootnote("Nothing to download. A dictation too long for the model is inserted without cleanup.")
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
        }
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
        case .authFailed(let message):
            if let message {
                TextAIFootnote("✕ The server rejected the API key: \(message)", color: STheme.danger)
            } else {
                TextAIFootnote("✕ The server rejected the API key", color: STheme.danger)
            }
        case .requestFailed(let message):
            TextAIFootnote("✕ A test request failed: \(message)", color: STheme.danger)
        case .unreachable:
            TextAIFootnote(isRemote
                           ? "✕ Can't reach the server. Check the URL."
                           : "✕ Can't reach Ollama. Is it running? (ollama serve)",
                           color: STheme.danger)
        }
    }
}
