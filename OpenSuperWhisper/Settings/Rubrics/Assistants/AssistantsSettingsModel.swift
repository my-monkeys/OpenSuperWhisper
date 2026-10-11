import SwiftUI

/// State behind Settings › Assistants: the Claude Code plugin, which agents are answered, the
/// moments that bring the panel up, and the projects. Each preference is written as soon as it
/// changes, exactly as the old Agents pane did.
@MainActor
final class AssistantsSettingsModel: ObservableObject {
    /// nil until the background check answers.
    @Published private(set) var status: ClaudeCodePlugin.Status?
    @Published private(set) var working = false
    /// What the install or removal is doing right now, shown in place of the status hint.
    @Published private(set) var step: String?
    @Published private(set) var error: String?
    @Published private(set) var codexHasPlugin = false

    @Published var claudeOn = AppPreferences.shared.agentKindEnabled(.claudeCode) {
        didSet { AppPreferences.shared.setAgentKind(.claudeCode, enabled: claudeOn) }
    }
    @Published var codexOn = AppPreferences.shared.agentKindEnabled(.codex) {
        didSet { AppPreferences.shared.setAgentKind(.codex, enabled: codexOn) }
    }
    @Published var askOnStop = AppPreferences.shared.agentAskOnStop {
        didSet { AppPreferences.shared.agentAskOnStop = askOnStop }
    }
    @Published var askOnPermission = AppPreferences.shared.agentAskOnPermission {
        didSet { AppPreferences.shared.agentAskOnPermission = askOnPermission }
    }
    @Published var askOnQuestion = AppPreferences.shared.agentAskOnQuestion {
        didSet { AppPreferences.shared.agentAskOnQuestion = askOnQuestion }
    }
    @Published var waitSeconds = AppPreferences.shared.agentWaitSeconds {
        didSet { AppPreferences.shared.agentWaitSeconds = waitSeconds }
    }
    @Published private(set) var projects: [String] = []
    @Published private(set) var disabledProjects: [String] = []

    /// The moments and projects only matter while some agent is answered.
    var enabled: Bool { claudeOn || codexOn }

    init() { refreshProjects() }

    func checkPlugins() async {
        status = await ClaudeCodePlugin.status()
        codexHasPlugin = CodexPlugin.isEnabled()
    }

    func install() { change { await ClaudeCodePlugin.install(step: $0) } }
    func uninstall() { change { await ClaudeCodePlugin.uninstall(step: $0) } }

    private func change(
        _ action: @escaping (@escaping @MainActor (String) -> Void) async -> Result<Void, ClaudeCodePlugin.PluginError>
    ) {
        working = true
        step = nil
        error = nil
        Task {
            let result = await action { [weak self] in self?.step = $0 }
            working = false
            step = nil
            if case .failure(let failure) = result { error = failure.message }
            status = await ClaudeCodePlugin.status()
        }
    }

    func refreshProjects() {
        disabledProjects = AppPreferences.shared.agentDisabledProjects
        projects = AgentSettings.listedProjects(recent: AppPreferences.shared.agentRecentProjects,
                                                     disabled: disabledProjects)
    }

    /// On when no turned-off folder (or its own switch) keeps the project in the terminal.
    func isProjectOn(_ path: String) -> Bool {
        AppPreferences.agentProjectTurnedOff(path, by: disabledProjects) == nil
    }

    func setProject(_ path: String, on: Bool) {
        AppPreferences.shared.setAgentProject(path, enabled: on)
        disabledProjects = AppPreferences.shared.agentDisabledProjects
    }

    func folderTurningOff(_ path: String) -> String? {
        AgentSettings.folderTurningOff(path, disabled: disabledProjects)
    }

    func projectsOnlyTurnedOff(by folder: String) -> Int {
        AgentSettings.projectsOnlyTurnedOff(by: folder, among: projects, disabled: disabledProjects)
    }

    /// "opensuperwhisper · site · 2 others": the first followed projects by name.
    var projectsSummary: String {
        let followed = projects.filter(isProjectOn).map { URL(fileURLWithPath: $0).lastPathComponent }
        guard !followed.isEmpty else {
            return projects.isEmpty
                ? String(localized: "None yet")
                : String(localized: "All turned off")
        }
        let shown = followed.prefix(2).joined(separator: " · ")
        let others = followed.count - 2
        guard others > 0 else { return shown }
        return shown + " · " + (others == 1
            ? String(localized: "1 other")
            : String(localized: "\(others) others"))
    }
}
