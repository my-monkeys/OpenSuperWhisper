import SwiftUI
import AppKit
import OpenSuperWhisperCore

/// What the preset menu currently points at: a built-in service, Custom, or a user-saved preset.
enum RemotePresetSelection: Equatable {
    case custom
    case service(RemoteService)
    case user(UUID)
}

/// Remote engine settings (Settings → Engine & Model when browsing "Remote"). A service picker
/// switches between the built-in services that offer transcription (pre-filled address and
/// models, see `RemoteService`) and a fully custom OpenAI-compatible server. All write the same
/// `remoteServer*` preferences and activate the single `"remote"` engine; the choice is just a
/// convenience prefill.

struct RemoteSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var selection: RemotePresetSelection
    @State private var userPresets: [RemoteUserPreset] = RemoteUserPresets.all()
    @State private var showSavePrompt = false
    @State private var newPresetName = ""

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        // Infer the selection from the configured URL/model so re-opening Settings
        // shows the right label (a saved preset wins over the built-in service heuristic).
        if let match = RemoteUserPresets.matching(
            url: viewModel.remoteServerURL, model: viewModel.remoteServerModel) {
            _selection = State(initialValue: .user(match.id))
        } else {
            _selection = State(initialValue:
                RemoteService.detect(url: viewModel.remoteServerURL).map { .service($0) } ?? .custom)
        }
    }

    private var selectionLabel: String {
        switch selection {
        case .custom: return "Custom"
        case .service(let service): return service.displayName
        case .user(let id): return userPresets.first { $0.id == id }?.name ?? "Custom"
        }
    }

    var body: some View {
        RemoteServerSettingsView(viewModel: viewModel) {
            SettingRow("Service", hint: "A built-in service fills in the address and models. Custom takes any OpenAI-compatible server.") {
                SMenu(Text(verbatim: DictationRubric.middleTruncated(selectionLabel))) {
                    Button("Custom") { select(.custom) }
                    ForEach(RemoteService.transcriptionServices) { service in
                        Button(service.displayName) { select(.service(service)) }
                    }
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
                }
            }
            .alert("Save preset", isPresented: $showSavePrompt) {
                TextField("Name (e.g. Home LiteLLM)", text: $newPresetName)
                Button("Save") { saveCurrentAsPreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current server URL, model, timeout and API key so you can switch back in one click.")
            }
        }
    }

    /// Prefill (built-in service), restore (user preset) or clear (Custom) the server config.
    /// Selecting a model/activating the engine happens in the sub-views.
    private func select(_ newSelection: RemotePresetSelection) {
        selection = newSelection
        switch newSelection {
        case .service(let service):
            if RemoteService.detect(url: viewModel.remoteServerURL) != service {
                viewModel.remoteServerURL = service.baseURL
            }
            if !service.transcriptionModels.contains(where: { $0.id == viewModel.remoteServerModel }) {
                viewModel.remoteServerModel = service.defaultTranscriptionModel ?? ""
            }
        case .custom:
            // Leaving a built-in service: clear its URL/model so the user can enter their own.
            if RemoteService.detect(url: viewModel.remoteServerURL) != nil {
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

