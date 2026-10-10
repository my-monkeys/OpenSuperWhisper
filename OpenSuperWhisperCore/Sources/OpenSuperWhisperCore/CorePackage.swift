internal import OSWNative

/// Read from a header macro, so a hosted test can check the core compiles against OSWNative.
let whisperSampleRate = Int(WHISPER_SAMPLE_RATE)

/// Lets the hosted tests check that the core lives in the app image and not in the test bundle.
final class CoreBundleMarker {}
