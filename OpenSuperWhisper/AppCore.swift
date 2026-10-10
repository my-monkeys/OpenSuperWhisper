import AppKit
import OpenSuperWhisperCore

/// What the macOS app hands the transcription core. Installing evaluates none of it, so
/// AppPreferences is still created the first time something reads it, in the GUI, the CLI and
/// the agent hook alike.
enum AppCore {
    private static let configuration = CoreConfiguration(
        preferences: { AppPreferences.shared },
        storageRoot: { AppIdentity.storageRoot()! },
        vadModelPath: { Bundle(for: WhisperEngine.self).path(forResource: "ggml-silero-v5.1.2", ofType: "bin") },
        textFormatter: { AutocorrectWrapper.format($0) },
        computePolicy: .automatic,
        makeSettings: { Settings() },
        confirmEnableHistory: { confirmEnableHistory() })

    /// Idempotent, because a SwiftUI preview never runs main and calls this from its body.
    static func install() {
        guard !CoreConfiguration.isInstalled else { return }
        CoreConfiguration.install(configuration)
    }

    /// Asks before a dropped file is saved while transcription history is off. The one place the
    /// app shows this alert; the queue reaches it through the core configuration.
    @MainActor
    static func confirmEnableHistory() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Transcription History Disabled"
        alert.informativeText = "Transcription saving is currently disabled. Would you like to enable it so this recording can be saved?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable & Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// UserDefaults and the Keychain are thread-safe, and the property wrappers hold only their key
/// and default. Engines already read these preferences from detached tasks and from
/// BuiltInLlamaBackend's inference queue.
extension AppPreferences: @unchecked Sendable, CorePreferences {}
