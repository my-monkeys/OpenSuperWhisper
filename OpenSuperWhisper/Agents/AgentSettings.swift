import Foundation
import OpenSuperWhisperCore

/// The rules behind the Assistants rubric's project list and wait menu, kept apart from the
/// views so they can be tested.
enum AgentSettings {
    /// The turned-off folder above `path` that keeps it off whatever its own switch says. The
    /// project's own entry is left out, so it survives while the folder is off and the row
    /// reads it again once the folder is back on.
    static func folderTurningOff(_ path: String, disabled: [String]) -> String? {
        AppPreferences.agentProjectTurnedOff(path, by: disabled.filter { $0 != path })
    }

    /// How many of `projects` turning `folder` back on would bring back to the panel: the ones
    /// a nearer turned-off folder, or their own switch, keeps off are left out.
    static func projectsOnlyTurnedOff(by folder: String, among projects: [String], disabled: [String]) -> Int {
        projects.filter { $0 != folder && AppPreferences.agentProjectTurnedOff($0, by: disabled) == folder }.count
    }

    /// The recent projects, after the turned-off folders that are not among them. A folder that
    /// left the recent list (or was never in it) still keeps everything below it in the
    /// terminal, and this list is the only place to turn it back on.
    static func listedProjects(recent: [String], disabled: [String]) -> [String] {
        disabled.filter { !recent.contains($0) }.sorted() + recent
    }

    static func label(forWait seconds: Int) -> String {
        seconds >= 590 ? "10 min" : "\(seconds / 60) min"
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let insideHome = path == home || path.hasPrefix(home + "/")
        return insideHome ? "~" + path.dropFirst(home.count) : path
    }
}
