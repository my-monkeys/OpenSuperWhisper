import Foundation

/// Single switch point for on-disk storage locations. Cycle 4 flips these to the
/// App Group container (`group.fr.my-monkey.opensuperwhisper`); until then each
/// computed URL is byte-identical to the per-site computations it replaced
/// (plan Key Decision #9).
public enum StorageLocations {

    /// ~/Library/Application Support/<bundle-id> — the app-scoped support dir.
    /// Hardened for framework use (Cycle-1 review): the force unwraps inherited from
    /// the app-target per-site computations are replaced with fallbacks that reproduce
    /// the standard locations, so production behavior is unchanged and a pathological
    /// host degrades to a stable directory instead of crashing.
    public static var appSupportDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "OpenSuperWhisper"
        return applicationSupport.appendingPathComponent(bundleIdentifier)
    }

    /// <appSupport>/recordings — recorded audio files.
    public static var recordingsDirectory: URL {
        appSupportDirectory.appendingPathComponent("recordings")
    }

    /// <appSupport>/recordings.sqlite — the GRDB recordings database.
    public static var recordingsDatabaseURL: URL {
        appSupportDirectory.appendingPathComponent("recordings.sqlite")
    }

    /// <appSupport>/whisper-models — downloaded whisper model files.
    public static var whisperModelsDirectory: URL {
        appSupportDirectory.appendingPathComponent("whisper-models")
    }

    /// <appSupport>/sensevoice-model — SenseVoice (sherpa-onnx) model + tokens.
    public static var senseVoiceModelDirectory: URL {
        appSupportDirectory.appendingPathComponent("sensevoice-model")
    }
}
