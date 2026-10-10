import Foundation

public enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}

/// Pins the domain an `NSError` made from this error carries. Swift derives it from the module
/// name, and the type used to live in the app, so moving it would have turned
/// "(OpenSuperWhisper.TranscriptionError error 2.)" into another text in the engine error label,
/// the failed-recording text in the database, the CLI and onboarding.
extension TranscriptionError: CustomNSError {
    public static var errorDomain: String { "OpenSuperWhisper.TranscriptionError" }
}
