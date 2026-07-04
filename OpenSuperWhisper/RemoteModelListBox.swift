import SwiftUI

/// One model from an OpenAI-compatible `GET /v1/models`.
struct RemoteModelInfo: Identifiable, Equatable {
    let id: String          // model id, e.g. "whisper-1"
    let ownedBy: String?    // OpenAI /v1/models "owned_by"
}

/// Shared `GET /v1/models` plumbing for any OpenAI-compatible server. Pure, so the
/// URL normalization and JSON parsing are unit-testable and identical everywhere
/// (the Remote transcription engine and the Remote LLM-cleanup both use it).
enum RemoteModelsAPI {
    /// `<base>/v1/models`, tolerating a base that lacks a scheme, has a trailing
    /// slash, or already includes `/v1`.
    static func modelsEndpoint(base: String) -> URL? {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/v1/models")
    }

    /// OpenAI shape: `{"data":[{"id":"…","owned_by":"…"}]}`, sorted by id.
    static func parse(_ data: Data) -> [RemoteModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> RemoteModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            return RemoteModelInfo(id: id, ownedBy: item["owned_by"] as? String)
        }.sorted { $0.id < $1.id }
    }
}

/// Reusable model picker for any OpenAI-compatible server: a bounded, searchable,
/// scrollable list of the models from `GET /v1/models`, plus a "Custom…" row that
/// reveals a free-text field (for servers that don't list models, or a wildcard).
///
/// Shared by the Remote transcription engine (`RemoteServerSettingsView`) and the
/// Remote LLM-cleanup settings — they differ only in which models they prefer
/// (STT vs chat, via `preferred`) and what picking a row does (via `onPick`).
struct RemoteModelListBox: View {
    let models: [RemoteModelInfo]
    /// Whether "Custom…" is the current choice (drives the free-text field below).
    @Binding var isCustom: Bool
    /// The free-text custom model id.
    @Binding var customText: String
    let customPrompt: String
    /// Model ids passing this are shown by default; the rest hide behind "show all".
    let preferred: (String) -> Bool
    /// Plural noun for the hidden count, e.g. "speech-to-text" or "chat".
    let hiddenKindLabel: String
    /// The id currently selected (radio-filled + ACTIVE tag), nil when Custom is
    /// selected or nothing is active.
    let selectedID: String?
    /// True when the Custom row is the active selection (ACTIVE tag on Custom).
    let customSelected: Bool
    let onPick: (String) -> Void
    let onPickCustom: () -> Void

    @State private var showAllModels = false
    @State private var modelSearchText = ""

    // /v1/models has no capability field, so servers list EVERYTHING — chat,
    // embeddings, TTS — alongside the ones we want. Default to the preferred kind;
    // fail open when nothing matches, and always offer "show all".
    private var preferredModels: [RemoteModelInfo] {
        guard !showAllModels else { return models }
        let filtered = models.filter { preferred($0.id) }
        return filtered.isEmpty ? models : filtered
    }

    private var visibleModels: [RemoteModelInfo] {
        let base = preferredModels
        let query = modelSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    // Counts only the preferred filter (not the search box), so the "show all"
    // label stays truthful while a search is active.
    private var hiddenModelCount: Int { models.count - preferredModels.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Aggregators (LiteLLM, gateways) can list hundreds of models — a filter
            // box beats scrolling. Hidden for short lists.
            if models.count > 5 {
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

            // Bounded scroll box: shows a handful and scrolls for more, so a server
            // with many models doesn't blow up the panel.
            ScrollView {
                VStack(spacing: 0) {
                    if visibleModels.isEmpty && !modelSearchText.isEmpty {
                        Text("No models match \"\(modelSearchText)\"")
                            .font(.system(size: 11)).foregroundColor(STheme.hint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    }
                    ForEach(visibleModels) { info in
                        modelRow(name: info.id, selected: !isCustom && selectedID == info.id) {
                            isCustom = false
                            onPick(info.id)
                        }
                        Rectangle().fill(STheme.border).frame(height: 1)
                    }
                    modelRow(name: "Custom…", selected: customSelected) {
                        isCustom = true
                        onPickCustom()
                    }
                }
            }
            .frame(height: models.isEmpty ? 44 : 176)
            .background(RoundedRectangle(cornerRadius: 9).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            // Key the list to the fetched set so a delta (Test surfaces new models)
            // forces SwiftUI to rebuild.
            .id(models.map(\.id).joined(separator: "|"))

            if hiddenModelCount > 0 || showAllModels {
                Button {
                    showAllModels.toggle()
                } label: {
                    Group {
                        if showAllModels {
                            Text("Show only \(hiddenKindLabel) models")
                        } else {
                            Text("Show all \(models.count) models ")
                                .foregroundColor(STheme.text.opacity(0.85))
                            + Text("(\(hiddenModelCount) don't look like \(hiddenKindLabel))")
                                .foregroundColor(STheme.hint)
                        }
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
            }

            if models.isEmpty {
                // Make the auth-gated listing discoverable: Groq & co return 401 on
                // GET /v1/models without credentials, so the list stays empty until
                // a key is set and Test Connection runs.
                Text("The server's models are listed here after a successful Test Connection — most providers (e.g. Groq) need the API key set first.")
                    .font(.system(size: 11)).foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isCustom {
                TextField("", text: $customText, prompt: Text(customPrompt))
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
}
