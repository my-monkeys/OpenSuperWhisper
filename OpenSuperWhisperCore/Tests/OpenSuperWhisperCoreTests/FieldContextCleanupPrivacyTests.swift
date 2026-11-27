import XCTest
@testable import OpenSuperWhisperCore

/// The second outbound sink. LLM cleanup posts the transcript — and, through the system prompt,
/// the app's writing style and the user's own corrections — to whatever server is configured. The
/// focused field's text must never be part of what it posts (#89).
///
/// WHAT THIS PROVES: the cleanup request is built from exactly two strings and carries them
/// verbatim, so nothing is added on the way out; and `generate` sends the same request this test
/// inspects, because the builder is the only place one is made.
/// WHAT IT CANNOT PROVE: that no other code path can build a request carrying field text. It
/// also cannot see the text arriving by a route nobody anticipated. That is the same limitation
/// the transcription sink has, and the same answer: the structural scan keeps a new sink from
/// appearing, and a person has to read any new one against `FieldContext`.
final class FieldContextCleanupPrivacyTests: CoreTestCase {

    private func backend(disableReasoning: Bool = false) -> RemoteBackend {
        RemoteBackend(endpoint: "https://cleanup.example.test/v1", model: "test-model",
                      apiKey: "sk-test", disableReasoning: disableReasoning)
    }

    /// The shape, pinned. An added parameter, a prompt fragment or a context string changes this
    /// request, which is what makes the absence of field text a real property rather than an
    /// assertion that could never fail.
    func testTheCleanupRequestIsTheTwoMessagesAndNothingElse() throws {
        let request = try backend().request(for: "USER TEXT", system: "SYSTEM PROMPT")

        XCTAssertEqual(request.url?.absoluteString,
                       "https://cleanup.example.test/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["model", "temperature", "stream", "messages"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "SYSTEM PROMPT")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "USER TEXT")
    }

    /// The two strings are carried through, not re-templated. A sentinel is the cheapest way to
    /// say that: whatever the caller passes is what leaves, so there is no slot for anything else
    /// to be slipped into.
    ///
    /// Deliberately no "the field text is absent" assertion here: nothing field-shaped is in
    /// scope on this API, so such an assertion could never fail. That is the vacuous green this
    /// suite exists to avoid, and the structural scan is the instrument for absence.
    func testTheTwoStringsLeaveVerbatim() throws {
        let request = try backend(disableReasoning: true)
            .request(for: "ZQX-USER-SENTINEL", system: "ZQX-SYSTEM-SENTINEL")

        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        let text = try XCTUnwrap(body)
        XCTAssertTrue(text.contains("ZQX-USER-SENTINEL"))
        XCTAssertTrue(text.contains("ZQX-SYSTEM-SENTINEL"))
    }

    /// With no usable endpoint there is no request at all, rather than one pointing somewhere
    /// unexpected. The caller falls back to the raw transcript.
    func testAnUnusableEndpointThrowsInsteadOfBuildingARequest() {
        let backend = RemoteBackend(endpoint: "   ", model: "m", apiKey: "k")

        XCTAssertThrowsError(try backend.request(for: "USER", system: "SYSTEM")) { error in
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }
    }
}
