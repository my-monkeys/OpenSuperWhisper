import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// A Swift error that reaches the user as an `NSError` carries its type's module in the domain:
/// the engine error label, the failed-recording text in the database, the CLI and onboarding all
/// show "(OpenSuperWhisper.TranscriptionError error 2.)". Moving the type into another module
/// must not change that text. Only the domain and the code are pinned, because the rest of
/// `localizedDescription` follows the Mac's language.
final class ErrorBridgingTests: XCTestCase {

    func testTranscriptionErrorKeepsItsDomainAndCodes() {
        let errors: [TranscriptionError] = [
            .contextInitializationFailed,
            .audioConversionFailed,
            .processingFailed,
        ]

        for (code, error) in errors.enumerated() {
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, "OpenSuperWhisper.TranscriptionError", "\(error)")
            XCTAssertEqual(bridged.code, code, "\(error)")
        }
    }
}
