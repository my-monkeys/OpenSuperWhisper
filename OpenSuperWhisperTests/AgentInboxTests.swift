import XCTest
@testable import OpenSuperWhisper

/// What the inbox reads off the hook's files. The panel shows exactly this list, so a request
/// listed after the user answered it comes back on screen.
final class AgentInboxTests: XCTestCase {
    private var requests: URL!
    private var responses: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osw-inbox-\(UUID())")
        requests = root.appendingPathComponent("requests")
        responses = root.appendingPathComponent("responses")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: requests.deletingLastPathComponent())
    }

    /// A request whose hook is this test process, so it counts as still waiting.
    private func writeRequest(createdAt: Date, hookPID: Int32 = getpid()) throws -> AgentRequest {
        let request = AgentRequest(
            id: UUID().uuidString, kind: .stop, agent: "Claude Code", sessionID: "s",
            cwd: "/Users/me/code/site", message: "Done.", createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(600), hookPID: hookPID)
        try AgentBridge.write(request, to: requests.appendingPathComponent("\(request.id).json"))
        return request
    }

    private func load(now: Date) -> [AgentRequest] {
        AgentInbox.loadRequests(now: now, requests: requests, responses: responses)
    }

    func testAnAnsweredRequestStaysHiddenUntilItsHookCleansUp() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let answered = try writeRequest(createdAt: now)
        let waiting = try writeRequest(createdAt: now.addingTimeInterval(1))
        try AgentBridge.write(AgentResponse(action: .reply, text: "Deploy it."),
                              to: responses.appendingPathComponent("\(answered.id).json"))

        XCTAssertEqual(load(now: now.addingTimeInterval(2)).map(\.id), [waiting.id])
        // The hook still has to find its answer next to its request.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: requests.appendingPathComponent("\(answered.id).json").path))
    }

    func testRequestsWithoutAnAnswerAreListedOldestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let newer = try writeRequest(createdAt: now.addingTimeInterval(5))
        let older = try writeRequest(createdAt: now)
        XCTAssertEqual(load(now: now.addingTimeInterval(6)).map(\.id), [older.id, newer.id])
    }

    func testARequestWhoseHookIsGoneIsDroppedAndDeleted() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let orphan = try writeRequest(createdAt: now, hookPID: 0)
        XCTAssertTrue(load(now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: requests.appendingPathComponent("\(orphan.id).json").path))
    }

    func testAnAnswerWhoseHookIsGoneIsDeletedWithItsRequest() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let orphan = try writeRequest(createdAt: now, hookPID: 0)
        let response = responses.appendingPathComponent("\(orphan.id).json")
        try AgentBridge.write(AgentResponse(action: .reply, text: "Deploy it."), to: response)
        XCTAssertTrue(load(now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.path))
    }
}
