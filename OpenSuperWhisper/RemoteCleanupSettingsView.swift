import SwiftUI
import OpenSuperWhisperCore

/// Configuration for the Remote (OpenAI-compatible) LLM-cleanup backend: server URL,
/// optional API key, Test Connection, and a chat-model picker fetched from
/// `GET /v1/models`. The model list UI is the very same `RemoteModelListBox` the
/// Remote transcription engine uses — here it prefers chat models and just sets the
/// cleanup model (no engine activation). Connection status is published to
/// `viewModel.llmStatus`, rendered by the parent next to the fields. Drawn as `SettingRow`s, so
/// it belongs inside a `SettingsGroup` card.
struct RemoteCleanupSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var availableModels: [RemoteModelInfo] = []
    @State private var isCustomModel = true
    @State private var revealKey = false
    @State private var autoTestTask: Task<Void, Never>?
    @State private var storedKey: String?
    @State private var confirmsCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow("Server",
                       hint: "Unencrypted http:// unless you type https://.",
                       indented: true) {
                STextField("https://api.groq.com/openai/v1", text: $viewModel.aiRemoteEndpoint,
                           monospaced: true, width: 260)
                    .autocorrectionDisabled(true)
            }

            SettingRow("API key",
                       hint: "Only for servers with accounts (Groq, OpenAI…). Kept in your Keychain.",
                       indented: true) {
                HStack(spacing: 8) {
                    Group {
                        if revealKey {
                            TextField("", text: $viewModel.aiRemoteAPIKey, prompt: Text("optional"))
                        } else {
                            SecureField("", text: $viewModel.aiRemoteAPIKey, prompt: Text("optional"))
                        }
                    }
                    .textFieldStyle(.plain)
                    .scaledFont(size: 13, design: .monospaced)
                    .foregroundColor(STheme.textBright)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 220)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .scaledFont(size: 13)
                            .foregroundColor(STheme.hint)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(revealKey ? "Hide key" : "Reveal key")
                    if storedKey != nil { savedBadge }
                }
            }

            SettingRow("Connection", indented: true) {
                HStack(spacing: 8) {
                    if viewModel.hasRemoteEngineConfig {
                        Button("Copy from Remote engine", action: copyFromRemoteEngine)
                            .buttonStyle(.sSecondary)
                            .help("Fill the server and API key from your Remote transcription engine")
                    }
                    Button("Test Connection") { runTest(probesChat: true) }
                        .buttonStyle(.sSecondary)
                        .disabled(viewModel.aiRemoteEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                                  || viewModel.llmStatus == .checking)
                }
            }

            SettingRow("Server model", stacked: true, indented: true) {
                RemoteModelListBox(
                    models: availableModels,
                    isCustom: $isCustomModel,
                    customText: $viewModel.aiRemoteModel,
                    customPrompt: "llama-3.1-8b-instant",
                    preferred: RemoteModelFilter.isLikelyChat,
                    hiddenKindLabel: "chat",
                    selectedID: isCustomModel ? nil : viewModel.aiRemoteModel,
                    customSelected: isCustomModel,
                    onPick: { viewModel.aiRemoteModel = $0 },
                    onPickCustom: { }
                )
            }
        }
        // Auto-fill the list on open and after edits settle, like the Remote engine.
        .onAppear {
            storedKey = AppPreferences.shared.aiRemoteAPIKey
            if !viewModel.aiRemoteEndpoint.isEmpty { runTest(probesChat: true) }
        }
        .onChange(of: viewModel.aiRemoteEndpoint) { _, _ in scheduleAutoTest() }
        .onChange(of: viewModel.aiRemoteAPIKey) { _, _ in
            // The field writes the Keychain on every keystroke before this runs, so reading it
            // back shows what is really stored.
            storedKey = AppPreferences.shared.aiRemoteAPIKey
            scheduleAutoTest()
        }
        .confirmationDialog("Replace the API key?", isPresented: $confirmsCopy) {
            Button("Replace", role: .destructive) { viewModel.copyRemoteEngineConfig() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The key saved for cleanup will be replaced by the one from your Remote transcription engine.")
        }
    }

    /// Confirms the write once it is in the Keychain, and which key it is.
    private var savedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            if let hint = RemoteCleanupKey.suffixHint(of: storedKey) {
                Text("Saved · \(hint)")
            } else {
                Text("Saved")
            }
        }
        .scaledFont(size: 12)
        .foregroundColor(STheme.ok)
        .lineLimit(1)
        .fixedSize()
    }

    private func copyFromRemoteEngine() {
        let incoming = AppPreferences.shared.remoteServerAPIKey ?? ""
        if RemoteCleanupKey.copyNeedsConfirmation(current: viewModel.aiRemoteAPIKey, incoming: incoming) {
            confirmsCopy = true
        } else {
            viewModel.copyRemoteEngineConfig()
        }
    }

    // Debounced re-test so we don't hammer the server on every keystroke. Only the cheap model
    // listing: a chat request per keystroke would cost tokens and trip rate limits.
    private func scheduleAutoTest() {
        autoTestTask?.cancel()
        autoTestTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if !viewModel.aiRemoteEndpoint.isEmpty { runTest() }
            }
        }
    }

    /// Probe GET /v1/models: publish reachability to `llmStatus` and fill the model list. With
    /// `probesChat`, a reachable server is then sent a tiny real chat request with the chosen
    /// model and key, because the listing proves neither (OpenRouter answers it without a key).
    /// A missing key is no reason to skip it: a server that needs one says so with a 401, and a
    /// local server that does not answers like any other.
    private func runTest(probesChat: Bool = false) {
        viewModel.llmStatus = .checking
        let urlString = viewModel.aiRemoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.aiRemoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = viewModel.aiRemoteModel.trimmingCharacters(in: .whitespaces)
        guard let endpoint = RemoteModelsAPI.modelsEndpoint(base: urlString) else {
            viewModel.llmStatus = .unreachable
            return
        }
        Task {
            var request = URLRequest(url: endpoint, timeoutInterval: 8)
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let models = (200..<300).contains(code) ? RemoteModelsAPI.parse(data) : []
                await MainActor.run {
                    if !models.isEmpty { applyFetched(models) }
                    if (200..<300).contains(code) {
                        if probesChat, !model.isEmpty {
                            probeChat(endpoint: urlString, model: model, apiKey: apiKey)
                        } else {
                            viewModel.llmStatus = .ok
                        }
                    } else if code == 401 || code == 403 {
                        viewModel.llmStatus = .authFailed(nil)
                    } else {
                        viewModel.llmStatus = .unreachable
                    }
                }
            } catch {
                await MainActor.run { viewModel.llmStatus = .unreachable }
            }
        }
    }

    private func probeChat(endpoint: String, model: String, apiKey: String) {
        Task {
            let status = await LLMPostProcessor.checkRemoteChat(endpoint: endpoint, model: model, apiKey: apiKey)
            await MainActor.run { viewModel.llmStatus = status }
        }
    }

    // Store the fetched models and decide whether the current model maps to a listed
    // one (row selected) or should stay custom (free-text shown).
    private func applyFetched(_ models: [RemoteModelInfo]) {
        availableModels = models
        let current = viewModel.aiRemoteModel.trimmingCharacters(in: .whitespaces)
        if models.contains(where: { $0.id == current }) {
            isCustomModel = false
        } else if !current.isEmpty {
            isCustomModel = true
        } else {
            isCustomModel = false
        }
    }
}
