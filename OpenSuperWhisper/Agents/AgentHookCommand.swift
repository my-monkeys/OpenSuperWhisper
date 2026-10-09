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
        guard AppPreferences.shared.agentsEnabled else { exit(0) }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
        let request: AgentRequest?
        switch event {
        case "stop": request = makeStopRequest(from: input)
        case "permission": request = makePermissionRequest(from: json)
        case "question": request = makeQuestionRequest(from: json)
        default: request = nil
        }
        guard let request,
              let requestURL = AgentBridge.requestURL(request.id),
              let responseURL = AgentBridge.responseURL(request.id),
              (try? AgentBridge.write(request, to: requestURL)) != nil else { exit(0) }

        DistributedNotificationCenter.default().postNotificationName(
            AgentBridge.requestNotification, object: request.id, userInfo: nil, deliverImmediately: true)

        let response = waitForResponse(at: responseURL, until: request.expiresAt)
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: responseURL)
        if let output = output(for: request.kind, response: response, hookInput: json) {
            FileHandle.standardOutput.write(output)
        }
        exit(0)
    }

    static func output(for kind: AgentRequest.Kind, response: AgentResponse?,
                       hookInput: [String: Any]) -> Data? {
        switch kind {
        case .stop: return stopHookOutput(for: response)
        case .permission: return permissionHookOutput(for: response)
        case .question: return questionHookOutput(for: response, toolInput: hookInput["tool_input"] as? [String: Any])
        }
    }

    private static func baseRequest(kind: AgentRequest.Kind, json: [String: Any], message: String,
                                    now: Date, pid: Int32) -> AgentRequest {
        AgentRequest(
            id: UUID().uuidString,
            kind: kind,
            agent: "Claude Code",
            sessionID: (json["session_id"] as? String) ?? "",
            title: (json["transcript_path"] as? String).flatMap(sessionTitle(transcriptPath:)),
            cwd: (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
            message: message,
            createdAt: now,
            expiresAt: now.addingTimeInterval(maxWait),
            hookPID: pid)
    }

    static func makePermissionRequest(from json: [String: Any], now: Date = Date(),
                                      pid: Int32 = getpid()) -> AgentRequest? {
        guard let tool = json["tool_name"] as? String else { return nil }
        let input = (json["tool_input"] as? [String: Any]) ?? [:]
        var request = baseRequest(kind: .permission, json: json,
                                  message: (input["description"] as? String) ?? "", now: now, pid: pid)
        request.tool = tool
        request.toolDetail = toolDetail(tool: tool, input: input)
        return request
    }

    static func makeQuestionRequest(from json: [String: Any], now: Date = Date(),
                                    pid: Int32 = getpid()) -> AgentRequest? {
        guard let input = json["tool_input"] as? [String: Any],
              let raw = input["questions"] as? [[String: Any]] else { return nil }
        let questions: [AgentQuestion] = raw.compactMap { item in
            guard let question = item["question"] as? String else { return nil }
            let options = ((item["options"] as? [[String: Any]]) ?? []).compactMap { option -> AgentQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return AgentQuestion.Option(label: label, description: option["description"] as? String)
            }
            return AgentQuestion(question: question, header: item["header"] as? String,
                                 options: options, multiSelect: (item["multiSelect"] as? Bool) ?? false)
        }
        guard !questions.isEmpty else { return nil }
        var request = baseRequest(kind: .question, json: json, message: "", now: now, pid: pid)
        request.questions = questions
        return request
    }

    /// What the tool is about to do, in the form a person checks: the command, the file, the
    /// address. Anything else falls back to its input, as compact JSON.
    static func toolDetail(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "url", "pattern", "path", "query"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(2_000))
    }

    /// Allow or deny, in the shape PermissionRequest expects. A dismissal prints nothing, and
    /// Claude Code shows its own prompt in the terminal as usual.
    static func permissionHookOutput(for response: AgentResponse?) -> Data? {
        guard let response else { return nil }
        var decision: [String: Any]
        switch response.action {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = ["behavior": "deny",
                        "message": text.isEmpty ? "The user declined this, from OpenSuperWhisper." : text]
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ])
    }

    /// The answers go in the tool's own input, which the hook returns whole: Claude Code then
    /// runs AskUserQuestion with them already filled in and never shows the prompt.
    static func questionHookOutput(for response: AgentResponse?, toolInput: [String: Any]?) -> Data? {
        guard let response, response.action == .answer, !response.answers.isEmpty,
              var updated = toolInput else { return nil }
        updated["answers"] = response.answers
        return try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated,
            ],
        ])
    }

    static func makeStopRequest(from input: Data, now: Date = Date(),
                                pid: Int32 = getpid()) -> AgentRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        let message = (json["last_assistant_message"] as? String) ?? ""
        return baseRequest(kind: .stop, json: json,
                           message: message.trimmingCharacters(in: .whitespacesAndNewlines), now: now, pid: pid)
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
