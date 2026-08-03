import XCTest
@testable import WhisperCore
@testable import OpenSuperWhisper

/// The Remote (OpenAI-compatible) cleanup backend builds `<base>/v1/chat/completions`
/// and `<base>/v1/models` from a user-typed server URL that may omit the scheme, carry a
/// trailing slash, or already include `/v1`. Same normalization contract as the Remote
/// transcription engine, plus the chat-completions response parsing.
final class LLMCleanupEndpointTests: XCTestCase {

    private func chat(_ base: String) -> String? {
        LLMPostProcessor.chatEndpoint(base: base)?.absoluteString
    }

    func testBuildsChatEndpoint() {
        XCTAssertEqual(chat("https://api.groq.com/openai/v1"),
                       "https://api.groq.com/openai/v1/chat/completions")
    }

    func testToleratesTrailingSlash() {
        XCTAssertEqual(chat("http://host:11434/"), "http://host:11434/v1/chat/completions")
    }

    func testDoesNotDuplicateV1() {
        XCTAssertEqual(chat("http://host/v1"), "http://host/v1/chat/completions")
        XCTAssertEqual(chat("http://host/v1/"), "http://host/v1/chat/completions")
    }

    func testDefaultsToHTTPWhenSchemeMissing() {
        XCTAssertEqual(chat("box.lan:8080"), "http://box.lan:8080/v1/chat/completions")
    }

    func testModelsEndpoint() {
        XCTAssertEqual(RemoteModelsAPI.modelsEndpoint(base: "https://api.groq.com/openai/v1")?.absoluteString,
                       "https://api.groq.com/openai/v1/models")
    }

    func testEmptyBaseIsNil() {
        XCTAssertNil(chat("   "))
    }

    func testExtractsChatContent() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"Hello, world."}}]}"#
        XCTAssertEqual(LLMPostProcessor.extractChatContent(from: Data(json.utf8)), "Hello, world.")
    }

    func testExtractChatContentReturnsNilOnGarbage() {
        XCTAssertNil(LLMPostProcessor.extractChatContent(from: Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertNil(LLMPostProcessor.extractChatContent(from: Data("not json".utf8)))
    }
}
