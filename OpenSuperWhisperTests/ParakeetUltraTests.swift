import XCTest
@testable import OpenSuperWhisper

/// Parakeet Ultra end to end: download, load, transcribe. Gated like the other Parakeet tests
/// because it fetches about 614 MB on first run.
final class ParakeetUltraTests: XCTestCase {

    func testUltraTranscribesJFK() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OSW_TEST_FLUIDAUDIO"] == "1",
                          "Needs the Parakeet Ultra models")
        let engine = FluidAudioEngine(versionOverride: "ultra")
        try await engine.initialize()
        let text = try await engine.transcribeAudio(url: Fixtures.jfkWav, settings: Settings())
        XCTAssertTrue(text.lowercased().contains("your country"), text)
    }
}
