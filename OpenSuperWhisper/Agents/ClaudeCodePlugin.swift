import Foundation

/// Installs and checks the Claude Code plugin through Claude Code's own CLI, the way the
/// plugin's README tells a user to. The app has no say over `~/.claude` beyond that.
enum ClaudeCodePlugin {
    static let marketplace = "my-monkeys/OpenSuperWhisper"
    static let pluginID = "opensuperwhisper@opensuperwhisper"

    enum Status: Equatable {
        case installed
        case notInstalled
        /// No `claude` command on this Mac.
        case noClaudeCode
    }

    /// Read from Claude Code's settings, where `claude plugin install` records the plugin as
    /// enabled; only when it is not there is a login shell asked whether Claude Code exists.
    /// Off the main thread: waiting on that shell spins the run loop, and doing it inside a
    /// SwiftUI update re-entered the view graph and crashed the app.
    static func status() async -> Status {
        await Task.detached {
            if isEnabledInSettings() { return Status.installed }
            return claudeExecutable() == nil ? .noClaudeCode : .notInstalled
        }.value
    }

    static func isEnabledInSettings() -> Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["enabledPlugins"] as? [String: Any] else { return false }
        return enabled[pluginID] as? Bool == true
    }

    /// `step` names what is running, for the pane to show: adding the marketplace clones the
    /// repository from GitHub and can take a while, and a bare spinner said nothing about it.
    static func install(step: @escaping @MainActor (String) -> Void) async -> Result<Void, PluginError> {
        await step("Adding the OpenSuperWhisper marketplace from GitHub…")
        // Adding a marketplace that is already there fails; that one is not a reason to stop.
        if case .failure(let error) = await run(["plugin", "marketplace", "add", marketplace]),
           !error.message.localizedCaseInsensitiveContains("already") {
            return .failure(error)
        }
        await step("Installing the plugin into Claude Code…")
        return await run(["plugin", "install", pluginID]).map { _ in }
    }

    static func uninstall(step: @escaping @MainActor (String) -> Void) async -> Result<Void, PluginError> {
        await step("Removing the plugin from Claude Code…")
        return await run(["plugin", "uninstall", pluginID]).map { _ in }
    }

    struct PluginError: Error, Equatable {
        let message: String
    }

    /// A GUI app gets launchd's bare PATH, without ~/.local/bin where Claude Code installs
    /// itself, so the command is looked up through a login shell, which reads the user's own.
    static func claudeExecutable() -> String? {
        let output = shell("command -v claude")
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    private static func run(_ arguments: [String]) async -> Result<String, PluginError> {
        await Task.detached {
            guard let claude = claudeExecutable() else {
                return .failure(PluginError(message: "Claude Code was not found on this Mac."))
            }
            let command = ([claude] + arguments).map(quoted).joined(separator: " ")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command + " 2>&1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do { try process.run() } catch {
                return .failure(PluginError(message: error.localizedDescription))
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return process.terminationStatus == 0
                ? .success(output)
                : .failure(PluginError(message: output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.value
    }

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func quoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

