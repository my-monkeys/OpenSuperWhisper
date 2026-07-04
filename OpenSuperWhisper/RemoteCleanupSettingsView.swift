import SwiftUI

/// Configuration for the Remote (OpenAI-compatible) LLM-cleanup backend: server URL,
/// optional API key, Test Connection, and a chat-model picker fetched from
/// `GET /v1/models`. The model list UI is the very same `RemoteModelListBox` the
/// Remote transcription engine uses — here it prefers chat models and just sets the
/// cleanup model (no engine activation). Connection status is published to
/// `viewModel.llmStatus`, rendered by the parent next to the fields.
struct RemoteCleanupSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var availableModels: [RemoteModelInfo] = []
    @State private var isCustomModel = true
    @State private var revealKey = false
    @State private var autoTestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SRow(title: "Server", indented: true) {
                TextField("", text: $viewModel.aiRemoteEndpoint,
                          prompt: Text("https://api.groq.com/openai/v1"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .frame(width: 260)
                    .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
            }

            SRow(title: "API key", hint: "Optional — only auth servers (Groq, OpenAI…) need one. Stored in your Keychain.", indented: true) {
                HStack(spacing: 8) {
                    Group {
                        if revealKey {
                            TextField("", text: $viewModel.aiRemoteAPIKey, prompt: Text("leave blank for no-auth servers"))
                        } else {
                            SecureField("", text: $viewModel.aiRemoteAPIKey, prompt: Text("leave blank for no-auth servers"))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .frame(width: 220)
                    .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundColor(STheme.hint)
                    }
                    .buttonStyle(.plain)
                    .help(revealKey ? "Hide key" : "Reveal key")
                }
            }

            HStack(spacing: 12) {
                Button("Test Connection") { runTest() }
                    .controlSize(.small)
                    .disabled(viewModel.aiRemoteEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                              || viewModel.llmStatus == .checking)
                if viewModel.hasRemoteEngineConfig {
                    Button("Copy from Remote engine") { viewModel.copyRemoteEngineConfig() }
                        .controlSize(.small)
                        .help("Fill the server and API key from your Remote transcription engine")
                }
                Spacer()
            }
            .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.system(size: 11)).foregroundColor(STheme.hint)
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
            .padding(.leading, 16)
        }
        // Auto-fill the list on open and after edits settle, like the Remote engine.
        .onAppear { if !viewModel.aiRemoteEndpoint.isEmpty { runTest() } }
        .onChange(of: viewModel.aiRemoteEndpoint) { _, _ in scheduleAutoTest() }
        .onChange(of: viewModel.aiRemoteAPIKey) { _, _ in scheduleAutoTest() }
    }

    // Debounced re-test so we don't hammer the server on every keystroke.
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

    /// Probe GET /v1/models: publish reachability to `llmStatus` and fill the model list.
    private func runTest() {
        viewModel.llmStatus = .checking
        let urlString = viewModel.aiRemoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.aiRemoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        viewModel.llmStatus = .ok
                    } else if code == 401 || code == 403 {
                        viewModel.llmStatus = .authFailed
                    } else {
                        viewModel.llmStatus = .unreachable
                    }
                }
            } catch {
                await MainActor.run { viewModel.llmStatus = .unreachable }
            }
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
