import Foundation
import WhisperCore

/// A user-saved Remote-engine configuration: everything needed to switch servers
/// in one click. The API key is deliberately NOT part of the Codable payload —
/// it lives in the Keychain under `remotePreset.<id>` (a secret never belongs in
/// UserDefaults) and is copied into the active slot when the preset is applied.
struct RemoteUserPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var model: String
    var timeoutEnabled: Bool
    var timeoutSeconds: Double
}

/// Persistence for user-defined Remote presets (JSON in AppPreferences, keys in
/// the Keychain). Pure CRUD — applying a preset to the live config is UI logic
/// (RemoteSettingsSection), so this stays trivially testable.
enum RemoteUserPresets {
    /// Posted after any add/remove so open UI (the preset menu) can refresh.
    static let didChangeNotification = Notification.Name("RemoteUserPresetsDidChange")

    static func all() -> [RemoteUserPreset] {
        let data = AppPreferences.shared.remoteUserPresetsData
        guard !data.isEmpty,
              let presets = try? JSONDecoder().decode([RemoteUserPreset].self, from: data) else {
            return []
        }
        return presets
    }

    static func add(_ preset: RemoteUserPreset, apiKey: String?) {
        var presets = all()
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        persist(presets)
        setAPIKey(apiKey, for: preset.id)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func remove(_ id: UUID) {
        var presets = all()
        presets.removeAll { $0.id == id }
        persist(presets)
        setAPIKey(nil, for: id) // never leave an orphaned secret behind
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func apiKey(for id: UUID) -> String? {
        Keychain.read(keychainAccount(for: id))
    }

    static func setAPIKey(_ key: String?, for id: UUID) {
        let value = (key?.isEmpty == false) ? key : nil
        Keychain.set(value, for: keychainAccount(for: id))
    }

    /// The saved preset matching the live config, if any — used to show the right
    /// menu label when Settings reopens.
    static func matching(url: String, model: String) -> RemoteUserPreset? {
        all().first { $0.serverURL == url && $0.model == model }
    }

    private static func persist(_ presets: [RemoteUserPreset]) {
        AppPreferences.shared.remoteUserPresetsData =
            (try? JSONEncoder().encode(presets)) ?? Data()
    }

    private static func keychainAccount(for id: UUID) -> String {
        "remotePreset.\(id.uuidString)"
    }
}
