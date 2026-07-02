import XCTest
@testable import OpenSuperWhisper

/// The Remote engine parses the server's success body for the transcript text
/// (OpenAI `{"text":...}`, tolerating `{"result":...}` or a bare string), and on
/// failure pulls a human-readable message from an error body. This guards both
/// parsers and their documented fallbacks.
final class RemoteResponseParsingTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - extractText

    func testExtractsOpenAITextKey() {
        XCTAssertEqual(RemoteEngine.extractText(from: data(#"{"text":"hello world"}"#)), "hello world")
    }

    func testExtractsResultKeyFallback() {
        XCTAssertEqual(RemoteEngine.extractText(from: data(#"{"result":"hi"}"#)), "hi")
    }

    func testExtractTextPassesThroughNonJSON() {
        XCTAssertEqual(RemoteEngine.extractText(from: data("plain text body")), "plain text body")
    }

    // MARK: - serverMessage

    func testServerMessageFromNestedError() {
        XCTAssertEqual(RemoteEngine.serverMessage(from: data(#"{"error":{"message":"bad model"}}"#)), "bad model")
    }

    func testServerMessageFromStringError() {
        XCTAssertEqual(RemoteEngine.serverMessage(from: data(#"{"error":"nope"}"#)), "nope")
    }

    func testServerMessageNilForEmptyBody() {
        XCTAssertNil(RemoteEngine.serverMessage(from: data("")))
    }
}
