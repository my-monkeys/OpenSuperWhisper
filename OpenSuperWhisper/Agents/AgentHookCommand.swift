import Foundation

/// `OpenSuperWhisper agent-hook <event>`: what the Claude Code plugin runs on each hook. Reads the
/// hook's JSON from stdin, hands the request to the running app, waits for the user, and prints
/// what Claude Code expects on stdout.
///
/// Every way out that is not an answer (the app gone, the user dismissing, the wait running out)
/// exits 0 with nothing printed, which Claude Code reads as "carry on as usual": the agent stops
/// and waits in its terminal exactly as it would without the plugin.
enum AgentHookCommand {
    /// Claude Code's own limit for the hook is set to 600 s in the plugin; giving up a little
    /// earlier lets this exit cleanly instead of being killed mid-write.
    static let maxWait: TimeInterval = 590
    static let pollInterval: TimeInterval = 0.2

    static func run(_ args: [String]) -> Never {
        let event = args.count >= 3 ? args[2] : ""
        guard event == "stop", AppPreferences.shared.agentsEnabled else { exit(0) }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = makeStopRequest(from: input) else { exit(0) }
        guard let requestURL = AgentBridge.requestURL(request.id),
              let responseURL = AgentBridge.responseURL(request.id),
              (try? AgentBridge.write(request, to: requestURL)) != nil else { exit(0) }

        DistributedNotificationCenter.default().postNotificationName(
            AgentBridge.requestNotification, object: request.id, userInfo: nil, deliverImmediately: true)

        let response = waitForResponse(at: responseURL, until: request.expiresAt)
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: responseURL)
        if let output = stopHookOutput(for: response) {
            FileHandle.standardOutput.write(output)
        }
        exit(0)
    }

    static func makeStopRequest(from input: Data, now: Date = Date(),
                                pid: Int32 = getpid()) -> AgentRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        let message = (json["last_assistant_message"] as? String) ?? ""
        return AgentRequest(
            id: UUID().uuidString,
            kind: .stop,
            agent: "Claude Code",
            sessionID: (json["session_id"] as? String) ?? "",
            cwd: (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            expiresAt: now.addingTimeInterval(maxWait),
            hookPID: pid)
    }

    /// A Stop hook keeps the agent going by "blocking" the stop with a reason; the reason is what
    /// Claude reads next. Saying where it comes from keeps it from being taken for an error.
    static func stopHookOutput(for response: AgentResponse?) -> Data? {
        guard let response, response.action == .reply else { return nil }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let reason = "The user answered by voice, through OpenSuperWhisper:\n\n\(text)"
        return try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": reason])
    }

    private static func waitForResponse(at url: URL, until deadline: Date) -> AgentResponse? {
        while Date() < deadline {
            if let response = AgentBridge.read(AgentResponse.self, from: url) { return response }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }
}
