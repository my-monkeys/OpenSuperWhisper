import XCTest
import OpenSuperWhisperCore
@testable import OpenSuperWhisper

/// `RemoteService.detect` decides whether the Remote settings open on a built-in service (vs
/// Custom) from the configured server URL, and the service's model constants drive its curated
/// list. This guards that inference for Groq (case-insensitive, rejects others) and the
/// coherence of Groq's model constants.
final class GroqPresetTests: XCTestCase {

    func testDetectsGroqURLCaseInsensitively() {
        XCTAssertEqual(RemoteService.detect(url: "https://api.groq.com/openai/v1"), .groq)
        XCTAssertEqual(RemoteService.detect(url: "HTTPS://API.GROQ.COM/openai/v1"), .groq)
    }

    func testRejectsNonGroqURLs() {
        XCTAssertNotEqual(RemoteService.detect(url: "https://api.openai.com/v1"), .groq)
        XCTAssertNil(RemoteService.detect(url: "http://litellm.docker.lan:4000/v1"))
        XCTAssertNil(RemoteService.detect(url: ""))
    }

    func testModelConstantsAreCoherent() {
        // The translating model differs from the default (turbo is transcription-only),
        // and both are offered in the curated list.
        let groq = RemoteService.groq
        XCTAssertNotEqual(groq.defaultTranscriptionModel, groq.translatingModel)
        let ids = groq.transcriptionModels.map(\.id)
        XCTAssertTrue(ids.contains(groq.defaultTranscriptionModel!))
        XCTAssertTrue(ids.contains(groq.translatingModel!))
    }
}
