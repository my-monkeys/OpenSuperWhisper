import XCTest
@testable import OpenSuperWhisper

/// The Claude Code side of the agent panel: reading the Stop hook's input and writing what makes
/// Claude carry on. A wrong shape here fails silently in the user's terminal, so it is pinned.
final class AgentHookTests: XCTestCase {

    private func stopInput(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    func testStopRequestCarriesTheAgentsLastMessage() {
        let now = Date(timeIntervalSince1970: 1_000)
        let request = AgentHookCommand.makeStopRequest(
            from: stopInput(["session_id": "abc", "cwd": "/Users/me/code/site",
                             "last_assistant_message": "  Done. Shall I deploy?\n",
                             "stop_hook_active": false]),
            now: now, pid: 42)
        XCTAssertEqual(request?.kind, .stop)
        XCTAssertEqual(request?.sessionID, "abc")
        XCTAssertEqual(request?.projectName, "site")
        XCTAssertEqual(request?.message, "Done. Shall I deploy?")
        XCTAssertEqual(request?.hookPID, 42)
        XCTAssertEqual(request?.expiresAt, now.addingTimeInterval(AgentHookCommand.maxWait))
    }

    func testGarbageInputMakesNoRequest() {
        XCTAssertNil(AgentHookCommand.makeStopRequest(from: Data("not json".utf8)))
    }

    func testAReplyBlocksTheStopWithTheUsersWords() throws {
        let data = try XCTUnwrap(AgentHookCommand.stopHookOutput(
            for: AgentResponse(action: .reply, text: " Yes, deploy it. ")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json["decision"], "block")
        XCTAssertTrue(json["reason"]?.hasSuffix("Yes, deploy it.") == true)
    }

    func testDismissOrSilenceLetsTheAgentStop() {
        XCTAssertNil(AgentHookCommand.stopHookOutput(for: AgentResponse(action: .dismiss)))
        XCTAssertNil(AgentHookCommand.stopHookOutput(for: AgentResponse(action: .reply, text: "  ")))
        XCTAssertNil(AgentHookCommand.stopHookOutput(for: nil))
    }

    func testResponsesRoundTripThroughTheirFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osw-agent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentBridge.write(AgentResponse(action: .reply, text: "go"), to: url)
        XCTAssertEqual(AgentBridge.read(AgentResponse.self, from: url), AgentResponse(action: .reply, text: "go"))
    }

    func testADismissalWithoutTextStillDecodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osw-agent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"action":"dismiss"}"#.utf8).write(to: url)
        XCTAssertEqual(AgentBridge.read(AgentResponse.self, from: url), AgentResponse(action: .dismiss))
    }
}
