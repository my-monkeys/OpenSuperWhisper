import Foundation
import OpenSuperWhisperCore

/// One backend the regenerate panel can rerun the cleanup on.
struct CleanupBackendOption: Identifiable, Equatable {
    /// "apple" | "builtin" | "ollama" | "remote", as `AppPreferences.aiBackend` spells them.
    let tag: String
    let title: String
    /// The model id this Mac is configured with. Only Ollama and Remote have one to replace.
    let configuredModel: String?
    /// What the history keeps as `cleanupModel` when this backend answers with its configured model.
    let modelLabel: String

    var id: String { tag }
    var editsModel: Bool { configuredModel != nil }
}

/// The backends a cleanup can be rerun on: only those this Mac is set up for, so choosing one
/// never ends in "Backend not ready".
enum CleanupBackendOptions {
    struct Setup {
        var appleIntelligenceAvailable = false
        var builtInModelLabel: String?
        var ollamaEndpoint = ""
        var ollamaModel = ""
        var remoteEndpoint = ""
        var remoteModel = ""
    }

    static func available(_ setup: Setup) -> [CleanupBackendOption] {
        var options: [CleanupBackendOption] = []
        if setup.appleIntelligenceAvailable {
            options.append(CleanupBackendOption(tag: "apple", title: String(localized: "Apple Intelligence"),
                                                configuredModel: nil, modelLabel: "Apple Intelligence"))
        }
        if let label = setup.builtInModelLabel {
            options.append(CleanupBackendOption(tag: "builtin", title: String(localized: "Built-in (Qwen)"),
                                                configuredModel: nil, modelLabel: label))
        }
        if isSet(setup.ollamaEndpoint) {
            options.append(CleanupBackendOption(tag: "ollama", title: String(localized: "Ollama"),
                                                configuredModel: setup.ollamaModel,
                                                modelLabel: setup.ollamaModel.trimmingCharacters(in: .whitespaces)))
        }
        if isSet(setup.remoteEndpoint) {
            options.append(CleanupBackendOption(tag: "remote", title: String(localized: "Server"),
                                                configuredModel: setup.remoteModel,
                                                modelLabel: setup.remoteModel.trimmingCharacters(in: .whitespaces)))
        }
        return options
    }

    /// The backend the panel opens on: the one whose model did the row's first cleanup when this
    /// Mac still has it, else the one dictations use now, else the first there is.
    static func defaultTag(firstModel: String?, current: String, in options: [CleanupBackendOption]) -> String? {
        if let firstModel, let match = options.first(where: { $0.modelLabel == firstModel }) { return match.tag }
        return options.first { $0.tag == current }?.tag ?? options.first?.tag
    }

    @MainActor static func current() -> [CleanupBackendOption] {
        let prefs = AppPreferences.shared
        let builtIn = BuiltInLlamaBackend.shared
        return available(Setup(
            appleIntelligenceAvailable: prefs.appleIntelligenceAvailability == .available,
            builtInModelLabel: builtIn.isReady ? builtIn.modelLabel : nil,
            ollamaEndpoint: prefs.aiOllamaEndpoint, ollamaModel: prefs.aiOllamaModel,
            remoteEndpoint: prefs.aiRemoteEndpoint, remoteModel: prefs.aiRemoteModel))
    }

    private static func isSet(_ endpoint: String) -> Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
