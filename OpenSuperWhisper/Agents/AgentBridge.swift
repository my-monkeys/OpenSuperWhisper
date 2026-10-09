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
        AppIdentity.applicationSupportDirectory()?.appendingPathComponent("agents", isDirectory: true)
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

/// An agent waiting on the user.
struct AgentRequest: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// The agent finished its turn; the answer becomes its next instruction.
        case stop
    }

    let id: String
    let kind: Kind
    /// "Claude Code" today; the field is there for the other agents the same plugin shape fits.
    let agent: String
    let sessionID: String
    /// The project the agent runs in. Its last component is what the panel shows.
    let cwd: String
    /// What the agent said last, shown so the reply has its context.
    let message: String
    let createdAt: Date
    /// After this the hook has given up and exited; the panel drops the request.
    let expiresAt: Date
    /// The waiting hook. A dead one means Claude Code cancelled it (Esc, or its own timeout).
    let hookPID: Int32

    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

/// The user's answer to one request.
struct AgentResponse: Codable, Equatable {
    enum Action: String, Codable {
        /// Send `text` to the agent.
        case reply
        /// Let the agent stop as it would have without the plugin.
        case dismiss
    }

    let action: Action
    var text: String = ""
}
