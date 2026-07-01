import XCTest
@testable import OpenSuperWhisper

/// The Remote engine builds `<base>/v1/audio/<action>` from a user-typed server
/// URL that may omit the scheme, carry a trailing slash, or already include a
/// `/v1` segment. This guards that normalization so every reasonable base URL
/// resolves to exactly one correct endpoint — no missing scheme, no `//`, no
/// duplicated `/v1`.
final class RemoteEndpointTests: XCTestCase {

    private func url(_ base: String, _ action: String = "transcriptions") -> String? {
        RemoteEngine.endpoint(base: base, action: action)?.absoluteString
    }

    func testBuildsTranscriptionsEndpoint() {
        XCTAssertEqual(url("http://host:4000"), "http://host:4000/v1/audio/transcriptions")
    }

    func testToleratesTrailingSlash() {
        XCTAssertEqual(url("http://host:4000/"), "http://host:4000/v1/audio/transcriptions")
    }

    func testDoesNotDuplicateV1() {
        XCTAssertEqual(url("http://host/v1"), "http://host/v1/audio/transcriptions")
        XCTAssertEqual(url("http://host/v1/"), "http://host/v1/audio/transcriptions")
    }

    func testDefaultsToHTTPWhenSchemeMissing() {
        XCTAssertEqual(url("litellm.docker.lan:4000"),
                       "http://litellm.docker.lan:4000/v1/audio/transcriptions")
    }

    func testPreservesExplicitHTTPSAndTranslationsAction() {
        XCTAssertEqual(RemoteEngine.endpoint(base: "https://api.groq.com/openai/v1",
                                             action: "translations")?.absoluteString,
                       "https://api.groq.com/openai/v1/audio/translations")
    }
}
