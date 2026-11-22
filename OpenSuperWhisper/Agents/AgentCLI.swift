import Foundation

struct PluginError: Error, Equatable {
    let message: String
}

/// Finds and runs the command-line tool of an agent (`claude`, `codex`) that the app installs
/// its plugin through.
enum AgentCLI {
    /// A GUI app gets launchd's bare PATH, so the command is looked up through a login shell,
    /// which reads the user's own. nvm is the exception: it is loaded from `.zshrc` (often
    /// lazily), which a login shell never reads, so its node versions are searched directly.
    static func executable(named name: String) -> String? {
        let output = shell("command -v \(name)")
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.hasPrefix("/") { return path }
        return nvmExecutable(named: name, nvmDirectory: nvmDirectory())
    }

    /// The newest node version under nvm that has the command, as a Codex installed with
    /// `npm i -g` lands there.
    static func nvmExecutable(named name: String, nvmDirectory: URL) -> String? {
        let versions = nvmDirectory.appendingPathComponent("versions/node")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
        return names
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versions.appendingPathComponent($0).appendingPathComponent("bin/\(name)").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func nvmDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["NVM_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm")
    }

    /// Runs the command through a login shell, so a script like nvm's `codex` finds its `node`.
    static func run(_ name: String, _ arguments: [String], notFound: String) async -> Result<String, PluginError> {
        await Task.detached {
            guard let executable = executable(named: name) else {
                return .failure(PluginError(message: notFound))
            }
            let command = ([executable] + arguments).map(quoted).joined(separator: " ")
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
