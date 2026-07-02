import SwiftUI
import AppKit

/// Built-in presets for the generic remote (OpenAI-compatible) engine. Groq is a
/// preset that points the remote engine at Groq's API with a curated model list;
/// "Custom" exposes the full URL/model/timeout controls for any other server.
enum RemotePreset: String, CaseIterable, Identifiable {
    case groq
    case custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .groq: return "Groq"
        case .custom: return "Custom"
        }
    }
}

/// Groq preset constants. Groq is the OpenAI-compatible remote engine pointed at
/// Groq's API; only the base URL and the curated model list are fixed.
enum GroqPreset {
    static let baseURL = "https://api.groq.com/openai/v1"
    static let defaultModel = "whisper-large-v3-turbo"
    /// Only the full model translates to English; turbo is transcription-only.
    static let translatingModel = "whisper-large-v3"

    static func isGroqURL(_ url: String) -> Bool {
        url.lowercased().contains("api.groq.com")
    }

    struct Model: Identifiable {
        let id: String
        let desc: String
    }
    static let models = [
        Model(id: "whisper-large-v3-turbo", desc: "Fastest — transcription only"),
        Model(id: "whisper-large-v3", desc: "Supports Translate to English"),
    ]
}

/// Remote engine settings (Settings → Engine & Model when browsing "Remote"). A
/// preset picker switches between Groq (curated, pre-filled) and a fully custom
/// OpenAI-compatible server. Both write the same `remoteServer*` preferences and
/// activate the single `"remote"` engine; the preset is just a convenience prefill.
/// What the preset menu currently points at: a built-in, or a user-saved preset.
enum RemotePresetSelection: Equatable {
    case custom
    case groq
    case user(UUID)
}

struct RemoteSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var selection: RemotePresetSelection
    @State private var userPresets: [RemoteUserPreset] = RemoteUserPresets.all()
    @State private var showSavePrompt = false
    @State private var newPresetName = ""

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        // Infer the selection from the configured URL/model so re-opening Settings
        // shows the right label (a saved preset wins over the Groq heuristic).
        if let match = RemoteUserPresets.matching(
            url: viewModel.remoteServerURL, model: viewModel.remoteServerModel) {
            _selection = State(initialValue: .user(match.id))
        } else {
            _selection = State(initialValue:
                GroqPreset.isGroqURL(viewModel.remoteServerURL) ? .groq : .custom)
        }
    }

    private var selectionLabel: String {
        switch selection {
        case .custom: return "Custom"
        case .groq: return "Groq"
        case .user(let id): return userPresets.first { $0.id == id }?.name ?? "Custom"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote (OpenAI-compatible) Engine")
                .font(.headline)
                .foregroundColor(.primary)

            // The one engine family that leaves the device — say so once, here.
            Label("Audio is uploaded to the remote server — not necessarily on-device.",
                  systemImage: "cloud")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            // Compact preset dropdown. Default is Custom; Groq prefills the Groq URL
            // and model list (leaving the key for the user). "Request a preset…" opens
            // the issue tracker so people can ask for a new built-in provider.
            HStack(spacing: 8) {
                Text("Preset").foregroundColor(.secondary)
                Menu {
                    Button("Custom") { select(.custom) }
                    Button("Groq") { select(.groq) }
                    if !userPresets.isEmpty {
                        Divider()
                        ForEach(userPresets) { p in
                            Button(p.name) { select(.user(p.id)) }
                        }
                    }
                    Divider()
                    Button("Save current as preset…") {
                        newPresetName = ""
                        showSavePrompt = true
                    }
                    if case .user(let id) = selection,
                       let current = userPresets.first(where: { $0.id == id }) {
                        Button("Delete preset “\(current.name)”", role: .destructive) {
                            RemoteUserPresets.remove(id)
                            userPresets = RemoteUserPresets.all()
                            selection = .custom
                        }
                    }
                    Divider()
                    Button("Request a built-in preset…") {
                        if let url = URL(string: "https://github.com/my-monkeys/OpenSuperWhisper/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Text(selectionLabel)
                }
                .fixedSize()
                Spacer()
            }
            .alert("Save preset", isPresented: $showSavePrompt) {
                TextField("Name (e.g. Home LiteLLM)", text: $newPresetName)
                Button("Save") { saveCurrentAsPreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current server URL, model, timeout and API key so you can switch back in one click.")
            }

            // One uniform config UI; the preset menu just prefills its fields.
            RemoteServerSettingsView(viewModel: viewModel)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    /// Prefill (Groq), restore (user preset) or clear (Custom) the server config.
    /// Selecting a model/activating the engine happens in the sub-views.
    private func select(_ newSelection: RemotePresetSelection) {
        selection = newSelection
        switch newSelection {
        case .groq:
            if !GroqPreset.isGroqURL(viewModel.remoteServerURL) {
                viewModel.remoteServerURL = GroqPreset.baseURL
            }
            if !GroqPreset.models.contains(where: { $0.id == viewModel.remoteServerModel }) {
                viewModel.remoteServerModel = GroqPreset.defaultModel
            }
        case .custom:
            // Leaving Groq: clear the Groq URL/model so the user can enter their own.
            if GroqPreset.isGroqURL(viewModel.remoteServerURL) {
                viewModel.remoteServerURL = ""
                viewModel.remoteServerModel = ""
            }
        case .user(let id):
            guard let preset = userPresets.first(where: { $0.id == id }) else { return }
            viewModel.remoteServerURL = preset.serverURL
            viewModel.remoteServerModel = preset.model
            viewModel.remoteServerTimeoutEnabled = preset.timeoutEnabled
            viewModel.remoteServerTimeoutSeconds = preset.timeoutSeconds
            // Restore the preset's key into the active slot (may be empty = no auth).
            viewModel.remoteServerAPIKey = RemoteUserPresets.apiKey(for: id) ?? ""
        }
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = RemoteUserPreset(
            id: UUID(),
            name: name,
            serverURL: viewModel.remoteServerURL,
            model: viewModel.remoteServerModel,
            timeoutEnabled: viewModel.remoteServerTimeoutEnabled,
            timeoutSeconds: viewModel.remoteServerTimeoutSeconds
        )
        RemoteUserPresets.add(preset, apiKey: viewModel.remoteServerAPIKey)
        userPresets = RemoteUserPresets.all()
        selection = .user(preset.id)
    }
}

