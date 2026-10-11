import Foundation

/// One selectable dictation model across all engines. Used by the menu-bar model
/// picker and the per-app context rules.
public struct DictationModelOption: Codable, Equatable, Hashable, Sendable {
    /// "whisper" | "fluidaudio" | "sensevoice" | "remote" — matches AppPreferences.selectedEngine.
    public let engine: String
    /// whisper: model file path; fluidaudio: version ("v2"/"v3"); sensevoice: "default";
    /// remote: model id.
    public let identifier: String
    public let displayName: String

    public init(engine: String, identifier: String, displayName: String) {
        self.engine = engine
        self.identifier = identifier
        self.displayName = displayName
    }
}
