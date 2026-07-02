import SwiftUI
import AppKit

/// Configuration UI for a custom remote (OpenAI-compatible) transcription server.
/// Shown under the "Custom" preset of the Remote engine section: free-text URL,
/// optional API key, a model list fetched from GET /v1/models, and a request
/// timeout. The Groq preset uses its own curated UI (see RemoteSettingsSection).
struct RemoteServerSettingsView<PresetRow: View>: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The Preset row (menu + save/delete) — owned by RemoteSettingsSection, rendered
    /// as the first row of the Server section per the Atelier design.
    @ViewBuilder let presetRow: () -> PresetRow

    @State private var testStatus: TestStatus = .idle
    @State private var availableModels: [RemoteModelInfo] = []
    @State private var isCustomModel: Bool = true
    // Server config + timeout live under disclosures so the model list stays the
    // focus once configured. Server opens by default only when nothing is set yet.
    @State private var revealKey = false
    @State private var autoTestTask: Task<Void, Never>?
    @State private var showAllModels = false
    @State private var modelSearchText = ""

    private var hasKey: Bool { !viewModel.remoteServerAPIKey.isEmpty }

    enum TestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    struct RemoteModelInfo: Identifiable, Equatable {
        let id: String          // model id, e.g. "whisper-1"
        let ownedBy: String?    // OpenAI /v1/models "owned_by"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SSection(title: "Server") {
                presetRow()
                SRow(title: "Server URL") {
                    TextField("", text: $viewModel.remoteServerURL,
                              prompt: Text("http://localhost:11434"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(width: 280)
                        .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
                }
                SRow(title: "API key", hint: "Optional — only auth servers need one. Stored in your Keychain.") {
                    HStack(spacing: 8) {
                        Group {
                            if revealKey {
                                TextField("", text: $viewModel.remoteServerAPIKey,
                                          prompt: Text("leave blank for no-auth servers"))
                            } else {
                                SecureField("", text: $viewModel.remoteServerAPIKey,
                                            prompt: Text("leave blank for no-auth servers"))
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(width: 240)
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
                        .disabled(viewModel.remoteServerURL.isEmpty || testStatus == .testing)
                    statusLabel
                    Spacer()
                }
            }

            modelSection

            SSection(title: "Reliability") {
                SRow(title: "Request timeout",
                     hint: viewModel.remoteServerTimeoutEnabled
                        ? "Raise it for slow server-side pipelines"
                        : "No timeout — requests wait indefinitely") {
                    HStack(spacing: 8) {
                        if viewModel.remoteServerTimeoutEnabled {
                            TextField("", value: $viewModel.remoteServerTimeoutSeconds, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .frame(width: 56)
                                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
                            Text("s").font(.system(size: 11)).foregroundColor(STheme.hint)
                        }
                        SToggle(isOn: $viewModel.remoteServerTimeoutEnabled)
                    }
                }
                fallbackBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Auto-test on open (and after edits settle) — surfaces reachability and
        // refreshes the model list without a manual click.
        .onAppear { if !viewModel.remoteServerURL.isEmpty { runTest() } else { fetchModels() } }
        .onChange(of: viewModel.remoteServerURL) { _, _ in scheduleAutoTest() }
        .onChange(of: viewModel.remoteServerAPIKey) { _, _ in scheduleAutoTest() }
        // Granting the Local Network prompt re-activates the app — retry a
        // previously-failed test so the model list fills in without a manual click
        // (the first auto-test runs while the permission prompt is still up).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if case .failure = testStatus, !viewModel.remoteServerURL.isEmpty {
                runTest()
            }
        }
    }

    // Debounced auto-test: re-run a moment after the URL/key stops changing, so we
    // don't hammer the server on every keystroke.
    private func scheduleAutoTest() {
        autoTestTask?.cancel()
        autoTestTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if !viewModel.remoteServerURL.isEmpty { runTest() }
            }
        }
    }

    /// Downloaded on-device models eligible as a fallback. When "Translate to English"
    /// is on, only translation-capable engines qualify (see EngineCapabilities) — Parakeet
    /// and SenseVoice can't translate, so they're filtered out.
    private var localFallbackModels: [DictationModelOption] {
        let all = ModelCatalog.whisperModels() + ModelCatalog.parakeetModels() + ModelCatalog.senseVoiceModels()
        guard viewModel.translateToEnglish else { return all }
        return all.filter { EngineCapabilities.translationCapableEngines.contains($0.engine) }
    }

    /// Inner content of the "Local fallback" disclosure: use a downloaded on-device model
    /// when the remote server is unreachable (e.g. off-network). Off by default.
    /// Any on-device model downloaded at all — gates whether the fallback feature is
    /// even offered (no local model → nothing to fall back to).
    private var hasAnyLocalModel: Bool {
        !(ModelCatalog.whisperModels() + ModelCatalog.parakeetModels() + ModelCatalog.senseVoiceModels()).isEmpty
    }

    @ViewBuilder private var fallbackBody: some View {
        Group {
            if !hasAnyLocalModel {
                Text("To enable local fallback, download an on-device model first (Models → Whisper or Parakeet).")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SRow(title: "Local fallback", hint: "Transcribe locally if the server is unreachable") {
                    SToggle(isOn: $viewModel.remoteFallbackEnabled)
                }
                if viewModel.remoteFallbackEnabled {
                    let models = localFallbackModels
                    if models.isEmpty {
                        Text("Translate to English is on, but no Whisper model is downloaded — only Whisper supports translation. Download one under Models.")
                            .font(.system(size: 11)).foregroundColor(STheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 16)
                    } else {
                        SRow(title: "Fallback model", indented: true) {
                            Picker("", selection: $viewModel.remoteFallbackModel) {
                                ForEach(models, id: \.self) { model in
                                    Text(model.displayName).tag(DictationModelOption?.some(model))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if viewModel.translateToEnglish {
                            Text("Translate to English is on, so only Whisper models are offered — Parakeet and SenseVoice can't translate.")
                                .font(.system(size: 11)).foregroundColor(STheme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .onAppear { ensureFallbackSelection() }
        .onChange(of: viewModel.remoteFallbackEnabled) { _, _ in ensureFallbackSelection() }
        .onChange(of: viewModel.translateToEnglish) { _, _ in ensureFallbackSelection() }
    }

    /// When fallback is enabled, guarantee a valid model is selected (the only one, or
    /// the first) — an empty selection is functionally disabled, so we never leave it
    /// blank. Re-runs when Translate flips, since that changes the eligible set.
    private func ensureFallbackSelection() {
        guard viewModel.remoteFallbackEnabled else { return }
        let models = localFallbackModels
        guard !models.isEmpty else { return }
        if let current = viewModel.remoteFallbackModel, models.contains(current) { return }
        viewModel.remoteFallbackModel = models.first
    }

    // /v1/models has no capability field, so servers list EVERYTHING they serve —
    // chat models, embeddings, TTS — alongside the transcription ones. Default to
    // the models that look like speech-to-text (name heuristic); fail open when
    // nothing matches, and always offer "show all" since heuristics have misses.
    private var sttFilteredModels: [RemoteModelInfo] {
        guard !showAllModels else { return availableModels }
        let stt = availableModels.filter { RemoteModelFilter.isLikelySpeechToText($0.id) }
        return stt.isEmpty ? availableModels : stt
    }

    private var visibleModels: [RemoteModelInfo] {
        let base = sttFilteredModels
        let query = modelSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    // Counts only the speech-to-text filter (not the search box), so the
    // "show all" label stays truthful while a search is active.
    private var hiddenModelCount: Int { availableModels.count - sttFilteredModels.count }

    // Model list styled like the local downloaded-model list: each model from
    // GET /v1/models is a selectable row, plus a "Custom" row that reveals a
    // free-text field (for servers that don't list models, or a wildcard "*").
    private var modelSection: some View {
        SSection(title: "Model") {
            // Aggregators (LiteLLM, OpenRouter-style gateways) can list hundreds of
            // models — a filter box beats scrolling. Hidden for short lists.
            if availableModels.count > 5 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(STheme.hint)
                    TextField("", text: $modelSearchText, prompt: Text("Filter models…"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .autocorrectionDisabled(true)
                    if !modelSearchText.isEmpty {
                        Button { modelSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(STheme.hint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
            }

            // Bounded scroll box (definite height): shows a handful of models and
            // scrolls for more, so a server with many models doesn't blow up the panel.
            ScrollView {
                VStack(spacing: 0) {
                    if visibleModels.isEmpty && !modelSearchText.isEmpty {
                        Text("No models match \"\(modelSearchText)\"")
                            .font(.system(size: 11)).foregroundColor(STheme.hint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    }
                    ForEach(visibleModels) { info in
                        modelRow(
                            name: info.id,
                            selected: viewModel.selectedEngine == "remote" && !isCustomModel && viewModel.remoteServerModel == info.id
                        ) {
                            isCustomModel = false
                            // Selecting a remote model activates the Remote engine (browse ≠ select).
                            viewModel.selectRemote(info.id)
                        }
                        Rectangle().fill(STheme.border).frame(height: 1)
                    }
                    modelRow(
                        name: "Custom…",
                        selected: viewModel.selectedEngine == "remote" && isCustomModel
                    ) {
                        isCustomModel = true
                        // Activate Remote with whatever's in the custom field (may be edited below).
                        viewModel.selectRemote(viewModel.remoteServerModel)
                    }
                }
            }
            .frame(height: availableModels.isEmpty ? 44 : 176)
            .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            // Key the list to the fetched model set so a delta (e.g. Test
            // Connection surfaces a newly-granted model) forces SwiftUI to rebuild.
            .id(availableModels.map(\.id).joined(separator: "|"))

            if hiddenModelCount > 0 || showAllModels {
                Button {
                    showAllModels.toggle()
                } label: {
                    Group {
                        if showAllModels {
                            Text("Show only speech-to-text models")
                        } else {
                            Text("Show all \(availableModels.count) models ")
                                .foregroundColor(STheme.text.opacity(0.85))
                            + Text("(\(hiddenModelCount) don't look like speech-to-text)")
                                .foregroundColor(STheme.hint)
                        }
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
            }

            if availableModels.isEmpty {
                // Make the auth-gated listing discoverable: Groq & co return 401 on
                // GET /v1/models without credentials, so the list stays empty until
                // a key is set and Test Connection runs.
                Text("The server's models are listed here after a successful Test Connection — most providers (e.g. Groq) need the API key set first.")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isCustomModel {
                TextField("", text: $viewModel.remoteServerModel, prompt: Text("whisper-1"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
            }
        }
    }

    /// One model row: radio dot + mono id + ACTIVE tag when it's the live selection.
    private func modelRow(name: String, selected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Circle()
                    .fill(selected ? STheme.accent : Color.clear)
                    .overlay(Circle().stroke(selected ? STheme.accent : STheme.controlBorder, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(selected ? STheme.textBright : STheme.text)
                Spacer()
                if selected {
                    Text("ACTIVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(STheme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? STheme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Text("✓ \(message)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(STheme.ok)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Capsule().fill(STheme.okBg))
        case .failure(let message):
            Text("✕ \(message)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.12)))
                .lineLimit(1)
        }
    }

    private func runTest() {
        testStatus = .testing
        let urlString = viewModel.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.remoteServerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpoint = modelsEndpoint(from: urlString) else {
            testStatus = .failure("Invalid URL")
            return
        }

        Task {
            var request = URLRequest(url: endpoint)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let models = (200..<300).contains(code) ? Self.parseModels(data) : []
                await MainActor.run {
                    if !models.isEmpty { applyFetched(models) }
                    if (200..<400).contains(code) {
                        testStatus = .success(models.isEmpty ? "Reachable" : "Reachable — \(models.count) models")
                    } else if code == 401 || code == 403 {
                        // Server is reachable; it just needs credentials.
                        testStatus = .success("Reachable — set the API key")
                    } else {
                        testStatus = .failure("HTTP \(code)")
                    }
                }
            } catch {
                await MainActor.run {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }

    // Silent populate of the model list (no status side effects) — used when the
    // panel appears with a server already configured.
    private func fetchModels() {
        let urlString = viewModel.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.remoteServerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let endpoint = modelsEndpoint(from: urlString) else { return }
        Task {
            var request = URLRequest(url: endpoint)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return }
            let models = Self.parseModels(data)
            await MainActor.run { if !models.isEmpty { applyFetched(models) } }
        }
    }

    // Store the fetched models and decide whether the current selection maps to a
    // listed model (row selected) or should be treated as custom (free-text shown).
    private func applyFetched(_ models: [RemoteModelInfo]) {
        availableModels = models
        // Cache for the menu-bar model picker, which has no live fetch of its own.
        AppPreferences.shared.cachedRemoteModels = models.map(\.id)
        let current = viewModel.remoteServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if models.contains(where: { $0.id == current }) {
            isCustomModel = false
        } else if !current.isEmpty {
            isCustomModel = true   // keep their typed value visible/editable
        } else {
            isCustomModel = false  // nothing chosen yet — let them pick a row
        }
    }

    private static func parseModels(_ data: Data) -> [RemoteModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> RemoteModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            return RemoteModelInfo(id: id, ownedBy: item["owned_by"] as? String)
        }.sorted { $0.id < $1.id }
    }

    private func modelsEndpoint(from urlString: String) -> URL? {
        var base = urlString
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/v1/models")
    }
}


/// Name-based guess at whether a remote model id is a speech-to-text model.
/// `/v1/models` carries no capability metadata, so this is a curated keyword
/// list covering the STT families served by OpenAI-compatible providers (Groq,
/// OpenAI, Mistral, NVIDIA, speaches/faster-whisper, ElevenLabs, …). Misses are
/// fine — the UI fails open and always offers "show all" + a Custom field.
enum RemoteModelFilter {
    private static let sttMarkers: [String] = [
        "whisper", "transcribe", "transcription", "parakeet", "canary",
        "voxtral", "sensevoice", "paraformer", "moonshine", "conformer",
        "citrinet", "scribe", "wav2vec", "seamless", "granite-speech",
        "speech-to-text", "speech2text", "asr", "stt",
    ]
    private static let notSTTMarkers: [String] = ["tts", "text-to-speech"]

    static func isLikelySpeechToText(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        if notSTTMarkers.contains(where: { id.contains($0) }) { return false }
        return sttMarkers.contains(where: { id.contains($0) })
    }
}
