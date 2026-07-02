import XCTest
@testable import OpenSuperWhisper

/// The remote local-fallback triggers only on "can't use the server" errors —
/// unreachable / 5xx after retries — never on auth or a real client 4xx that a
/// local model wouldn't fix, and never on a non-remote error. This guards that
/// classification (same shape as the retry classifier). Also pins the central
/// translation-capability set the fallback picker and the translate toggle share.
final class TranscriptionServiceFallbackTests: XCTestCase {

    func testFallsBackOnNetworkAnd5xx() {
        XCTAssertTrue(TranscriptionService.shouldUseFallback(for: RemoteError.network(nil)))
        XCTAssertTrue(TranscriptionService.shouldUseFallback(for: RemoteError.network(URLError(.timedOut))))
        XCTAssertTrue(TranscriptionService.shouldUseFallback(for: RemoteError.api(500, "boom")))
        XCTAssertTrue(TranscriptionService.shouldUseFallback(for: RemoteError.api(503, nil)))
    }

    func testDoesNotFallBackOnAuth4xxOrNonRemote() {
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: RemoteError.missingAPIKey))
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: RemoteError.invalidAPIKey))
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: RemoteError.api(400, "bad request")))
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: RemoteError.api(404, nil)))
        // A local engine failure or cancellation must never trigger the remote fallback.
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: TranscriptionError.processingFailed))
        XCTAssertFalse(TranscriptionService.shouldUseFallback(for: CancellationError()))
    }

    func testTranslationCapableSetIsWhisperAndRemoteOnly() {
        XCTAssertTrue(EngineCapabilities.translationCapableEngines.contains("whisper"))
        XCTAssertTrue(EngineCapabilities.translationCapableEngines.contains("remote"))
        XCTAssertFalse(EngineCapabilities.translationCapableEngines.contains("fluidaudio"))
        XCTAssertFalse(EngineCapabilities.translationCapableEngines.contains("sensevoice"))
    }
}
