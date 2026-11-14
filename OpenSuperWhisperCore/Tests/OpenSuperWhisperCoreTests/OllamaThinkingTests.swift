import XCTest
@testable import OpenSuperWhisperCore

/// Turning Ollama's thinking off for a cleanup (#339): what `/api/show` allows decides what is sent.
final class OllamaThinkingTests: CoreTestCase {
    private func show(_ thinking: String?) -> Data {
        let field = thinking.map { ",\"thinking\":\($0)" } ?? ""
        return Data("{\"details\":{\"family\":\"gemma\"}\(field)}".utf8)
    }

    func testAModelThatCanTurnThinkingOffGetsFalse() {
        XCTAssertEqual(OllamaThinking.value(fromShow: show("{\"values\":[true,false],\"default\":true}")), .disabled)
        XCTAssertEqual(OllamaThinking.value(fromShow: show("{\"values\":[false]}")), .disabled)
    }

    func testAModelThatCannotStopThinkingGetsNothing() {
        XCTAssertNil(OllamaThinking.value(fromShow: show("{\"values\":[true]}")))
    }

    func testANamedLevelModelGetsLowOrItsFirstLevel() {
        XCTAssertEqual(OllamaThinking.value(fromShow: show("{\"values\":[\"medium\",\"low\",\"high\"]}")), .level("low"))
        XCTAssertEqual(OllamaThinking.value(fromShow: show("{\"values\":[\"minimal\",\"standard\"]}")), .level("minimal"))
    }

    func testNoThinkingMetadataGetsNothing() {
        XCTAssertNil(OllamaThinking.value(fromShow: show(nil)))
        XCTAssertNil(OllamaThinking.value(fromShow: show("{}")))
        XCTAssertNil(OllamaThinking.value(fromShow: show("{\"values\":[]}")))
    }

    func testAnUnreadableResponseGetsNothing() {
        XCTAssertNil(OllamaThinking.value(fromShow: Data("not json".utf8)))
        XCTAssertNil(OllamaThinking.value(fromShow: show("{\"values\":[1,2]}")))
        XCTAssertNil(OllamaThinking.value(fromShow: show("\"low\"")))
    }

    private func chatBody(think: OllamaThinking.Value?) throws -> NSDictionary {
        let data = try OllamaThinking.chatBody(model: "m", system: "S", user: "U", think: think)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testTheBodyCarriesNoThinkFieldByDefault() throws {
        let expected: NSDictionary = [
            "model": "m", "stream": false, "options": ["temperature": 0],
            "messages": [["role": "system", "content": "S"], ["role": "user", "content": "U"]],
        ]
        XCTAssertEqual(try chatBody(think: nil), expected)
    }

    func testTheBodyCarriesThinkFalseOrALevel() throws {
        XCTAssertEqual(try chatBody(think: .disabled)["think"] as? Bool, false)
        XCTAssertEqual(try chatBody(think: .level("low"))["think"] as? String, "low")
    }
}
