internal import OSWNative

/// The core's public namespace until the engines move in. The app does not call it yet.
public enum CorePackage {
    public static let name = "OpenSuperWhisperCore"
}

/// Read from a header macro, so it proves the OSWNative module resolves without linking any
/// native symbol: the app still links ggml from the libwhisper subproject.
let whisperSampleRate = Int(WHISPER_SAMPLE_RATE)

/// Lets the hosted tests check that the core lives in the app image and not in the test bundle.
final class CoreBundleMarker {}
