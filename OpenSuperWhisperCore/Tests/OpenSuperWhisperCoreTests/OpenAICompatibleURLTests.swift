import XCTest
@testable import OpenSuperWhisperCore

/// One builder serves chat, model listing and transcription. Gemini's base
/// (`…/v1beta/openai/`) holds its version segment in the middle of the path, where the old
/// "strip a trailing /v1, append /v1/…" logic produced `…/openai/v1/chat/completions`.
final class OpenAICompatibleURLTests: CoreTestCase {

    private func url(_ base: String, _ resource: String = "chat/completions") -> String? {
        OpenAICompatibleURL.endpoint(base: base, resource: resource)?.absoluteString
    }

    func testGeminiBaseKeepsItsOwnVersionSegment() {
        let gemini = "https://generativelanguage.googleapis.com/v1beta/openai/"
        XCTAssertEqual(url(gemini), "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(url(gemini, "models"), "https://generativelanguage.googleapis.com/v1beta/openai/models")
    }

    func testEveryBuiltInServiceResolvesToItsDocumentedPath() {
        XCTAssertEqual(url("https://openrouter.ai/api/v1"), "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.groq.com/openai/v1"), "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(url("https://api.mistral.ai/v1"), "https://api.mistral.ai/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1", "audio/transcriptions"),
                       "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(url("https://api.mistral.ai/v1", "audio/transcriptions"),
                       "https://api.mistral.ai/v1/audio/transcriptions")
        XCTAssertEqual(url("https://api.groq.com/openai/v1", "models"), "https://api.groq.com/openai/v1/models")
    }

    func testBareHostGetsV1() {
        XCTAssertEqual(url("http://localhost:4000"), "http://localhost:4000/v1/chat/completions")
        XCTAssertEqual(url("http://host:4000/", "models"), "http://host:4000/v1/models")
        XCTAssertEqual(url("http://host:4000", "audio/translations"), "http://host:4000/v1/audio/translations")
    }

    func testAnyVersionSegmentCounts() {
        XCTAssertEqual(url("http://host/v2"), "http://host/v2/chat/completions")
        XCTAssertEqual(url("http://host/api/V1/"), "http://host/api/V1/chat/completions")
        XCTAssertEqual(url("http://host/v1alpha2/openai"), "http://host/v1alpha2/openai/chat/completions")
    }

    func testPathThatOnlyLooksLikeAVersionGetsV1() {
        XCTAssertEqual(url("http://host/vault"), "http://host/vault/v1/chat/completions")
        XCTAssertEqual(url("http://host/openai"), "http://host/openai/v1/chat/completions")
    }

    func testSchemeDefaultsToHTTPAndExplicitHTTPSIsKept() {
        XCTAssertEqual(url("box.lan:8080"), "http://box.lan:8080/v1/chat/completions")
        XCTAssertEqual(url("  https://api.example.test/openai/v1/  "), "https://api.example.test/openai/v1/chat/completions")
    }

    func testEmptyBaseIsNil() {
        XCTAssertNil(url("   "))
    }
}
