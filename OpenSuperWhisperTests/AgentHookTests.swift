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
        XCTAssertEqual(request?.expiresAt, now.addingTimeInterval(AgentHookCommand.wait))
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

    // MARK: Permissions

    func testPermissionRequestShowsTheCommand() {
        let request = AgentHookCommand.makePermissionRequest(from: [
            "session_id": "s", "cwd": "/p", "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "Clean the build"],
        ])
        XCTAssertEqual(request?.kind, .permission)
        XCTAssertEqual(request?.tool, "Bash")
        XCTAssertEqual(request?.toolDetail, "rm -rf build")
        XCTAssertEqual(request?.message, "Clean the build")
    }

    private func decision(_ data: Data?) -> [String: Any]? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = json["hookSpecificOutput"] as? [String: Any] else { return nil }
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return specific["decision"] as? [String: Any]
    }

    func testAllowAndDenyInThePermissionShape() {
        XCTAssertEqual(decision(AgentHookCommand.permissionHookOutput(for: AgentResponse(action: .allow)))?["behavior"] as? String, "allow")
        let denied = decision(AgentHookCommand.permissionHookOutput(for: AgentResponse(action: .deny, text: "Use make clean")))
        XCTAssertEqual(denied?["behavior"] as? String, "deny")
        XCTAssertEqual(denied?["message"] as? String, "Use make clean")
        XCTAssertNil(AgentHookCommand.permissionHookOutput(for: AgentResponse(action: .dismiss)))
    }

    // MARK: Questions

    private let questionInput: [String: Any] = [
        "questions": [["question": "Which branch?", "header": "Branch", "multiSelect": false,
                       "options": [["label": "main", "description": "Ship it"], ["label": "dev"]]]],
    ]

    func testQuestionRequestKeepsTheOptions() {
        let request = AgentHookCommand.makeQuestionRequest(from: ["session_id": "s", "cwd": "/p",
                                                                  "tool_name": "AskUserQuestion",
                                                                  "tool_input": questionInput])
        XCTAssertEqual(request?.questions?.first?.options.map(\.label), ["main", "dev"])
        XCTAssertEqual(request?.questions?.first?.header, "Branch")
    }

    func testAnswersGoBackInsideTheToolInput() throws {
        let data = try XCTUnwrap(AgentHookCommand.questionHookOutput(
            for: AgentResponse(action: .answer, answers: ["Which branch?": "dev"]), toolInput: questionInput))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which branch?": "dev"])
        XCTAssertNotNil(updated["questions"], "the whole input goes back, not only the answers")
    }

    /// What Claude Code sends for AskUserQuestion, as recorded from a real session: the same
    /// tool input reaches the PreToolUse hook and, when that one prints nothing, PermissionRequest.
    private func askUserQuestionHook(_ event: String, input: [String: Any]) -> [String: Any] {
        var json: [String: Any] = [
            "session_id": "7d6e9f94-52f7-4ead-ad7a-75bbf7f014ba",
            "transcript_path": "/nonexistent/7d6e9f94.jsonl",
            "cwd": "/Users/me/code/topchef", "permission_mode": "default",
            "hook_event_name": event, "tool_name": "AskUserQuestion", "tool_input": input,
        ]
        if event == "PreToolUse" { json["tool_use_id"] = "toolu_01P15ACyJWZQfNtvpHZFAbPn" }
        return json
    }

    private let realQuestionInput: [String: Any] = [
        "questions": [[
            "question": "Le titre de la partie, on le garde où ?", "header": "Indice", "multiSelect": false,
            "options": [["label": "Nulle part sur l'Accueil (Recommandé)", "description": "Seulement le nom du jeu."],
                        ["label": "Sous le nom, certains jeux", "description": "Tu me dis lesquels."]],
        ]],
    ]

    func testARealPreToolUsePayloadMakesAQuestionCard() {
        let request = AgentHookCommand.makeQuestionRequest(from: askUserQuestionHook("PreToolUse", input: realQuestionInput))
        XCTAssertEqual(request?.kind, .question)
        XCTAssertEqual(request?.questions?.first?.options.map(\.label),
                       ["Nulle part sur l'Accueil (Recommandé)", "Sous le nom, certains jeux"])
        XCTAssertNil(request?.toolDetail)
    }

    /// The bug: once the question card had timed out, the permission for the same question
    /// showed its input as a JSON array, and allowing it would have refused the question.
    func testAskUserQuestionIsNeverTurnedIntoAPermissionCard() {
        XCTAssertNil(AgentHookCommand.makePermissionRequest(
            from: askUserQuestionHook("PermissionRequest", input: realQuestionInput)))
        XCTAssertNotNil(AgentHookCommand.makePermissionRequest(
            from: ["session_id": "s", "cwd": "/p", "tool_name": "Bash", "tool_input": ["command": "ls"]]),
            "other tools still ask")
    }

    private var stringifiedQuestionInput: [String: Any] {
        let options = #"[{"label":"main","description":"Ship it"},{"label":"dev"}]"#
        let questions = try! JSONSerialization.data(withJSONObject: [
            ["question": "Which branch?", "header": "Branch", "multiSelect": false, "options": options],
        ])
        return ["questions": String(decoding: questions, as: UTF8.self)]
    }

    func testQuestionsSentAsJSONTextStillMakeAQuestionCard() {
        let request = AgentHookCommand.makeQuestionRequest(
            from: askUserQuestionHook("PreToolUse", input: stringifiedQuestionInput))
        XCTAssertEqual(request?.questions?.first?.question, "Which branch?")
        XCTAssertEqual(request?.questions?.first?.options.map(\.label), ["main", "dev"])
        XCTAssertEqual(request?.questions?.first?.options.first?.description, "Ship it")
    }

    func testQuestionsSentAsJSONTextGoBackAsLists() throws {
        let data = try XCTUnwrap(AgentHookCommand.questionHookOutput(
            for: AgentResponse(action: .answer, answers: ["Which branch?": "dev"]), toolInput: stringifiedQuestionInput))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let updated = try XCTUnwrap((json["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])
        let questions = try XCTUnwrap(updated["questions"] as? [[String: Any]])
        XCTAssertEqual((questions.first?["options"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which branch?": "dev"])
    }

    func testTextThatIsNotAQuestionListMakesNoRequest() {
        XCTAssertNil(AgentHookCommand.makeQuestionRequest(
            from: askUserQuestionHook("PreToolUse", input: ["questions": "Which branch?"])))
    }

    // MARK: Spoken answers

    func testSpokenVerdicts() {
        XCTAssertEqual(AgentInbox.verdict("Oui."), true)
        XCTAssertEqual(AgentInbox.verdict("vas-y"), true)
        XCTAssertEqual(AgentInbox.verdict("d'accord"), true)
        XCTAssertEqual(AgentInbox.verdict("No"), false)
        XCTAssertEqual(AgentInbox.verdict("non merci"), false)
        XCTAssertNil(AgentInbox.verdict("no, use make clean instead of rm"))
        XCTAssertNil(AgentInbox.verdict(""))
    }

    func testSpokenOptionPicksTheMatchingLabel() {
        let question = AgentQuestion(question: "Which?", options: [.init(label: "Parakeet Ultra"), .init(label: "Whisper")])
        XCTAssertEqual(AgentInbox.option(matching: "parakeet ultra.", in: question), "Parakeet Ultra")
        XCTAssertEqual(AgentInbox.option(matching: "Let's go with Whisper", in: question), "Whisper")
        XCTAssertNil(AgentInbox.option(matching: "neither", in: question))
    }

    // MARK: The Agents pane's switches

    private func stopRequest(cwd: String) -> AgentRequest {
        AgentHookCommand.makeStopRequest(from: stopInput(["session_id": "s", "cwd": cwd]))!
    }

    func testADisabledProjectAndItsSubfoldersStayInTheTerminal() {
        let prefs = AppPreferences.shared
        let saved = (prefs.agentDisabledProjects, prefs.agentRecentProjects, prefs.agentAskOnStop, prefs.agentEnabledKinds)
        defer { (prefs.agentDisabledProjects, prefs.agentRecentProjects, prefs.agentAskOnStop, prefs.agentEnabledKinds) = saved }
        prefs.agentEnabledKinds = AgentKind.allCases.map(\.rawValue)
        prefs.agentAskOnStop = true
        prefs.agentDisabledProjects = []
        prefs.setAgentProject("/code/site", enabled: false)

        XCTAssertFalse(AgentHookCommand.shouldAsk(stopRequest(cwd: "/code/site")))
        XCTAssertFalse(AgentHookCommand.shouldAsk(stopRequest(cwd: "/code/site/docs")))
        XCTAssertTrue(AgentHookCommand.shouldAsk(stopRequest(cwd: "/code/site-v2")), "a prefix that is not a subfolder")
        XCTAssertEqual(prefs.agentRecentProjects.first, "/code/site-v2", "every project is remembered, asked or not")
    }

    func testTurningAMomentOffSkipsThePanel() {
        let prefs = AppPreferences.shared
        let saved = (prefs.agentAskOnStop, prefs.agentEnabledKinds)
        defer { (prefs.agentAskOnStop, prefs.agentEnabledKinds) = saved }
        prefs.agentEnabledKinds = AgentKind.allCases.map(\.rawValue)
        prefs.agentAskOnStop = false
        XCTAssertFalse(AgentHookCommand.shouldAsk(stopRequest(cwd: "/code/other")))
    }

    // MARK: Telling the agents apart

    func testCodexIsKnownByItsTurnID() {
        XCTAssertEqual(AgentKind.detect(input: ["turn_id": "t", "session_id": "s"], environment: [:]), .codex)
    }

    func testCodexIsKnownByItsPluginRootWithoutClaudesProjectDir() {
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["PLUGIN_ROOT": "/p"]), .codex)
    }

    func testClaudeCodeIsKnownByItsOwnFields() {
        XCTAssertEqual(AgentKind.detect(input: ["prompt_id": "p"], environment: [:]), .claudeCode)
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["CLAUDE_PROJECT_DIR": "/p",
                                                                  "PLUGIN_ROOT": "/p"]), .claudeCode)
    }

    func testCursorAndGeminiWinOverTheClaudeCompatibilityVariable() {
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["CURSOR_VERSION": "2", "CLAUDE_PROJECT_DIR": "/p"]), .cursor)
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["GEMINI_SESSION_ID": "g", "CLAUDE_PROJECT_DIR": "/p"]), .gemini)
    }

    func testPiAndOhMyPiAreKnownByTheirMarker() {
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["OSW_AGENT": "pi"]), .pi)
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["OSW_AGENT": "omp"]), .pi)
    }

    func testThePiMarkerWinsOverEveryOtherAgentsSigns() {
        let environment = ["OSW_AGENT": "omp", "CLAUDE_PROJECT_DIR": "/p", "PLUGIN_ROOT": "/p",
                           "CURSOR_VERSION": "2", "GEMINI_SESSION_ID": "g"]
        XCTAssertEqual(AgentKind.detect(input: ["prompt_id": "p", "turn_id": "t"], environment: environment), .pi)
    }

    func testAnUnknownMarkerValueIsIgnored() {
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["OSW_AGENT": "vim", "CLAUDE_PROJECT_DIR": "/p"]), .claudeCode)
        XCTAssertEqual(AgentKind.detect(input: [:], environment: ["OSW_AGENT": ""]), .unknown)
    }

    func testThePanelNamesThePiHostThatIsWaiting() {
        XCTAssertEqual(AgentKind.pi.label(environment: ["OSW_AGENT": "omp"]), "oh-my-pi")
        XCTAssertEqual(AgentKind.pi.label(environment: ["OSW_AGENT": "pi"]), "pi")
        XCTAssertEqual(AgentKind.claudeCode.label(environment: ["OSW_AGENT": "omp"]), "Claude Code")
    }

    func testPiIsAnsweredWithClaudeCodeTurnedOff() {
        let prefs = AppPreferences.shared
        let saved = (prefs.agentEnabledKinds, prefs.agentRecentProjects)
        defer { (prefs.agentEnabledKinds, prefs.agentRecentProjects) = saved }
        prefs.agentEnabledKinds = [AgentKind.pi.rawValue]
        prefs.agentRecentProjects = []
        var request = stopRequest(cwd: "/code/pi-only")
        request.source = .pi
        XCTAssertTrue(AgentHookCommand.shouldAsk(request))
        request.source = .claudeCode
        XCTAssertFalse(AgentHookCommand.shouldAsk(request))
        prefs.agentEnabledKinds = [AgentKind.claudeCode.rawValue]
        request.source = .pi
        XCTAssertFalse(AgentHookCommand.shouldAsk(request))
    }

    func testAnAgentTheUserDidNotTurnOnGetsNothing() {
        let prefs = AppPreferences.shared
        let saved = (prefs.agentEnabledKinds, prefs.agentRecentProjects)
        defer { (prefs.agentEnabledKinds, prefs.agentRecentProjects) = saved }
        prefs.agentEnabledKinds = [AgentKind.claudeCode.rawValue]
        prefs.agentRecentProjects = []
        var request = stopRequest(cwd: "/code/codex-only")
        request.source = .codex
        XCTAssertFalse(AgentHookCommand.shouldAsk(request))
        XCTAssertEqual(prefs.agentRecentProjects, [], "not even remembered")
        request.source = .claudeCode
        XCTAssertTrue(AgentHookCommand.shouldAsk(request))
    }

    func testCodexThreadNameIsTheLastOneForTheSession() {
        let index = """
        {"id":"a","thread_name":"First name","updated_at":"1"}
        {"id":"b","thread_name":"Other","updated_at":"2"}
        {"id":"a","thread_name":"Renamed","updated_at":"3"}
        """
        XCTAssertEqual(AgentHookCommand.codexThreadName(inIndex: index, sessionID: "a"), "Renamed")
        XCTAssertNil(AgentHookCommand.codexThreadName(inIndex: index, sessionID: "missing"))
    }

    func testCodexPluginStateIsReadFromItsConfig() {
        let on = """
        [plugins."opensuperwhisper@opensuperwhisper"]
        enabled = true

        [plugins."other@x"]
        enabled = false
        """
        XCTAssertTrue(CodexPlugin.isEnabled(inConfig: on))
        XCTAssertFalse(CodexPlugin.isEnabled(inConfig: on.replacingOccurrences(of: "enabled = true", with: "enabled = false")))
        XCTAssertFalse(CodexPlugin.isEnabled(inConfig: "[plugins.\"other@x\"]\nenabled = true"))
    }
}
