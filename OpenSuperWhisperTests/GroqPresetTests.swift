import XCTest
@testable import OpenSuperWhisper

/// `GroqPreset.isGroqURL` decides whether the Remote settings open on the Groq
/// preset (vs Custom) from the configured server URL, and the preset's model
/// constants drive its curated list. This guards that inference (case-insensitive,
/// rejects non-Groq) and the coherence of the model constants.
final class GroqPresetTests: XCTestCase {

    func testDetectsGroqURLCaseInsensitively() {
        XCTAssertTrue(GroqPreset.isGroqURL("https://api.groq.com/openai/v1"))
        XCTAssertTrue(GroqPreset.isGroqURL("HTTPS://API.GROQ.COM/openai/v1"))
    }

    func testRejectsNonGroqURLs() {
        XCTAssertFalse(GroqPreset.isGroqURL("http://litellm.docker.lan:4000/v1"))
        XCTAssertFalse(GroqPreset.isGroqURL("https://api.openai.com/v1"))
        XCTAssertFalse(GroqPreset.isGroqURL(""))
    }

    func testModelConstantsAreCoherent() {
        // The translating model differs from the default (turbo is transcription-only),
        // and both are offered in the curated list.
        XCTAssertNotEqual(GroqPreset.defaultModel, GroqPreset.translatingModel)
        let ids = GroqPreset.models.map(\.id)
        XCTAssertTrue(ids.contains(GroqPreset.defaultModel))
        XCTAssertTrue(ids.contains(GroqPreset.translatingModel))
    }
}
