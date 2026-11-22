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
            return AgentCLI.executable(named: "claude") == nil ? .noClaudeCode : .notInstalled
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

    private static func run(_ arguments: [String]) async -> Result<String, PluginError> {
        await AgentCLI.run("claude", arguments, notFound: "Claude Code was not found on this Mac.")
    }
}

/// Codex does not import Claude Code's plugin marketplaces (0.163 stopped), so the plugin is
/// added to it the same way as to Claude Code: through its own `codex plugin` commands.
enum CodexPlugin {
    enum Status: Equatable {
        case installed
        case notInstalled
        /// No `codex` command on this Mac.
        case noCodex
    }

    static let marketplaceCommand = ["plugin", "marketplace", "add", ClaudeCodePlugin.marketplace]
    static let installCommand = ["plugin", "add", ClaudeCodePlugin.pluginID]
    static let uninstallCommand = ["plugin", "remove", ClaudeCodePlugin.pluginID]

    /// Read from Codex's config, where `codex plugin add` records the plugin as enabled, the
    /// way Claude Code's is read: no process for the common case. Off the main thread for the
    /// same reason as Claude Code's.
    static func status() async -> Status {
        await Task.detached {
            if isEnabled() { return Status.installed }
            return AgentCLI.executable(named: "codex") == nil ? .noCodex : .notInstalled
        }.value
    }

    static func install(step: @escaping @MainActor (String) -> Void) async -> Result<Void, PluginError> {
        await step("Adding the OpenSuperWhisper marketplace from GitHub…")
        // Adding a marketplace that is already there is not a reason to stop.
        if case .failure(let error) = await run(marketplaceCommand),
           !error.message.localizedCaseInsensitiveContains("already") {
            return .failure(error)
        }
        await step("Installing the plugin into Codex…")
        return await run(installCommand).map { _ in }
    }

    static func uninstall(step: @escaping @MainActor (String) -> Void) async -> Result<Void, PluginError> {
        await step("Removing the plugin from Codex…")
        return await run(uninstallCommand).map { _ in }
    }

    private static func run(_ arguments: [String]) async -> Result<String, PluginError> {
        await AgentCLI.run("codex", arguments, notFound: "Codex was not found on this Mac.")
    }

    static func isEnabled() -> Bool {
        guard let text = try? String(contentsOf: configURL(), encoding: .utf8) else { return false }
        return isEnabled(inConfig: text)
    }

    /// Codex keeps its state in `$CODEX_HOME`, `~/.codex` by default.
    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }

    /// True when the plugin's table is there and says `enabled = true` before the next table.
    static func isEnabled(inConfig text: String) -> Bool {
        let header = "[plugins.\"\(ClaudeCodePlugin.pluginID)\"]"
        guard let start = text.range(of: header) else { return false }
        for line in text[start.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return false }
            if trimmed.replacingOccurrences(of: " ", with: "") == "enabled=true" { return true }
        }
        return false
    }
}
