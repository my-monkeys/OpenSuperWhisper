import Foundation
import OpenSuperWhisperCore

/// Temporary: the core's internal CoreAccess, spelled the same, so a file moves into the core
/// without an edit. Deleted when TranscriptionQueue moves (4.6).
enum CoreAccess {
    private static var configuration: CoreConfiguration {
        guard CoreConfiguration.isInstalled else { fatalError(CoreConfiguration.notInstalledMessage) }
        return AppCore.configuration
    }
    static var preferences: any CorePreferences { configuration.preferences() }
    static var storageRoot: URL { configuration.storageRoot() }
    static var vadModelPath: String? { configuration.vadModelPath() }
    @MainActor static func makeSettings() -> TranscriptionSettings { configuration.makeSettings() }
    @MainActor static func confirmEnableHistory() async -> Bool { await configuration.confirmEnableHistory() }
}
