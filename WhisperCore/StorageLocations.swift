import Foundation

/// Single switch point for on-disk storage locations. Cycle 4 flips these to the
/// App Group container (`group.fr.my-monkey.opensuperwhisper`); until then each
/// computed URL is byte-identical to the per-site computations it replaced
/// (plan Key Decision #9).
public enum StorageLocations {

    /// ~/Library/Application Support/<bundle-id> — the app-scoped support dir.
    public static var appSupportDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
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
}
