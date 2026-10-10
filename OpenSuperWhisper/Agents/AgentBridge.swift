import Darwin
import Foundation

/// The meeting point between a coding agent's hook and the running app. The hook (this same
/// binary, run as `OpenSuperWhisper agent-hook <event>` by the Claude Code plugin) drops a request
/// file, rings the app with a distributed notification, then waits for a response file. Files
/// rather than a socket: the hook outlives nothing, the app can pick up a request that arrived
/// while it was busy, and a crash on either side leaves something readable behind.
///
///     ~/Library/Application Support/<bundle id>/agents/
///         app.pid, app.executable     written by the running app, read by the plugin's script
///         requests/<id>.json          one per waiting agent
///         responses/<id>.json         the user's answer, consumed by the hook
enum AgentBridge {
    static let requestNotification = Notification.Name("fr.my-monkey.opensuperwhisper.agent.request")

    static var directory: URL? {
        AppIdentity.storageRoot()?.appendingPathComponent("agents", isDirectory: true)
    }

    static var requestsDirectory: URL? { directory?.appendingPathComponent("requests", isDirectory: true) }
    static var responsesDirectory: URL? { directory?.appendingPathComponent("responses", isDirectory: true) }

    static func requestURL(_ id: String) -> URL? { requestsDirectory?.appendingPathComponent("\(id).json") }
    static func responseURL(_ id: String) -> URL? { responsesDirectory?.appendingPathComponent("\(id).json") }

    /// Called at launch: tells the plugin's script which binary to run and that someone is
    /// listening. With no live app the script exits at once and Claude Code carries on as if
    /// the plugin were not there.
    static func registerRunningApp() {
        // A test host is a throwaway copy of the app: registering it would point the plugin at
        // a process that is about to exit, and turn the user's real agents away.
        guard !DefaultsStore.isRunningTests,
              let directory, let executable = Bundle.main.executableURL?.path else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(getpid()).write(to: directory.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        try? executable.write(to: directory.appendingPathComponent("app.executable"), atomically: true, encoding: .utf8)
    }

    static func isAlive(pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

/// Which coding agent ran the hook. One plugin serves several: Codex imports Claude Code's
/// plugin marketplaces on its own and runs the same hooks, so the hook has to tell them apart
/// from what it receives, and only answer for the agents the user turned on.
enum AgentKind: String, Codable, CaseIterable {
    case claudeCode
    case codex
    case cursor
    case gemini
    case unknown

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .unknown: return "Coding agent"
        }
    }

    /// The desktop app whose icon stands for this agent, when it is installed.
    var iconBundleID: String? {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .gemini, .unknown: return nil
        }
    }

    /// Reads the hook's stdin and environment. No field names the agent outright, so this goes
    /// by what each one adds: Codex sends a `turn_id` on every turn and sets `PLUGIN_ROOT`
    /// without `CLAUDE_PROJECT_DIR`; Cursor and Gemini set `CLAUDE_PROJECT_DIR` for
    /// compatibility, so they are checked before Claude Code's own markers.
    static func detect(input: [String: Any], environment: [String: String]) -> AgentKind {
        if input["turn_id"] != nil
            || (environment["PLUGIN_ROOT"] != nil && environment["CLAUDE_PROJECT_DIR"] == nil) {
            return .codex
        }
        if input["cursor_version"] != nil || environment["CURSOR_VERSION"] != nil { return .cursor }
        if environment["GEMINI_SESSION_ID"] != nil { return .gemini }
        if input["prompt_id"] != nil || input["scratchpad_dir"] != nil || input["effort"] != nil
            || environment["CLAUDE_PROJECT_DIR"] != nil {
            return .claudeCode
        }
        return .unknown
    }
}

/// An agent waiting on the user.
struct AgentRequest: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// The agent finished its turn; the answer becomes its next instruction.
        case stop
        /// The agent wants to run a tool it needs permission for.
        case permission
        /// The agent asked a multiple-choice question (its AskUserQuestion tool).
        case question
    }

    let id: String
    let kind: Kind
    /// "Claude Code" today; the field is there for the other agents the same plugin shape fits.
    let agent: String
    let sessionID: String
    /// The session's name in Claude Code: the one given with /rename, else the one it wrote
    /// itself. What tells two agents in the same project apart.
    var title: String? = nil
    /// The project the agent runs in. Its last component is what the panel shows.
    let cwd: String
    /// What the agent said last, shown so the reply has its context.
    let message: String
    let createdAt: Date
    /// After this the hook has given up and exited; the panel drops the request.
    let expiresAt: Date
    /// The waiting hook. A dead one means Claude Code cancelled it (Esc, or its own timeout).
    let hookPID: Int32
    /// For a permission: the tool, and what it would do (the command, the file, the URL).
    var tool: String? = nil
    var toolDetail: String? = nil
    /// For a question: what the agent asked, in its order.
    var questions: [AgentQuestion]? = nil
    /// The agent behind it, for its icon. Optional so a request written by an older hook
    /// still reads.
    var source: AgentKind? = nil

    var agentKind: AgentKind { source ?? .claudeCode }

    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var displayTitle: String {
        guard let title, !title.isEmpty else { return projectName }
        return title
    }
}

/// One question from the agent's AskUserQuestion tool.
struct AgentQuestion: Codable, Equatable {
    struct Option: Codable, Equatable {
        let label: String
        var description: String? = nil
    }

    let question: String
    var header: String? = nil
    let options: [Option]
    var multiSelect: Bool = false
}

/// The user's answer to one request.
struct AgentResponse: Codable, Equatable {
    enum Action: String, Codable {
        /// Send `text` to the agent.
        case reply
        /// Hand the request back to the terminal, as if the plugin were not there.
        case dismiss
        /// Let the tool run.
        case allow
        /// Refuse it; `text`, when given, tells the agent what to do instead.
        case deny
        /// The chosen options, keyed by question.
        case answer
    }

    let action: Action
    var text: String = ""
    var answers: [String: String] = [:]

    init(action: Action, text: String = "", answers: [String: String] = [:]) {
        self.action = action
        self.text = text
        self.answers = answers
    }

    /// `text` may be absent: a dismissal has nothing to say, and the synthesized decoder would
    /// reject it rather than use the default, leaving the hook waiting out its full timeout.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        answers = try container.decodeIfPresent([String: String].self, forKey: .answers) ?? [:]
    }
}
