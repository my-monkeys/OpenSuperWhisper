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
            title: (json["transcript_path"] as? String).flatMap(sessionTitle(transcriptPath:)),
            cwd: (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            expiresAt: now.addingTimeInterval(maxWait),
            hookPID: pid)
    }

    /// How far back from the end of the transcript to look. Claude Code writes the title
    /// records again on every turn, so the tail always has the current ones, and a long
    /// session's transcript runs to tens of megabytes.
    static let titleScanBytes = 4 << 20

    /// The session's name: the last name given with /rename, else the last one Claude Code
    /// wrote itself. nil when neither is there yet (a first turn may not have one).
    static func sessionTitle(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(titleScanBytes) ? size - UInt64(titleScanBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return sessionTitle(inTranscript: String(decoding: data, as: UTF8.self))
    }

    static func sessionTitle(inTranscript text: String) -> String? {
        var custom: String?
        var generated: String?
        for line in text.split(separator: "\n") where line.contains("title\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "custom-title": custom = (json["customTitle"] as? String) ?? custom
            case "ai-title": generated = (json["aiTitle"] as? String) ?? generated
            default: break
            }
        }
        let title = (custom ?? generated)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
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
