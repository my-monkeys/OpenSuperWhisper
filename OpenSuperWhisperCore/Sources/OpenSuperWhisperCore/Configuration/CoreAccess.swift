import Foundation

/// The core's only path to the host: each read copies the installed configuration out of its
/// slot, then calls the provider.
enum CoreAccess {
    static var preferences: any CorePreferences { CoreConfiguration.current.preferences() }
    static var storageRoot: URL { CoreConfiguration.current.storageRoot() }
    static var vadModelPath: String? { CoreConfiguration.current.vadModelPath() }
    static func formatText(_ text: String) -> String { CoreConfiguration.current.textFormatter(text) }
    static var computePolicy: ComputePolicy { CoreConfiguration.current.computePolicy }
    @MainActor static func makeSettings() -> TranscriptionSettings { CoreConfiguration.current.makeSettings() }
    @MainActor static func confirmEnableHistory() async -> Bool { await CoreConfiguration.current.confirmEnableHistory() }
}
