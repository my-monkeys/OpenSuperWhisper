import SwiftUI

/// State behind Settings › Assistants: the Claude Code and Codex plugins, which agents are
/// answered, the moments that bring the panel up, and the projects. Each preference is written
/// as soon as it changes, exactly as the old Agents pane did.
@MainActor
final class AssistantsSettingsModel: ObservableObject {
    /// nil until the background check answers.
    @Published private(set) var status: ClaudeCodePlugin.Status?
    /// nil until the background check answers.
    @Published private(set) var codexStatus: CodexPlugin.Status?
    /// The agent whose plugin an install or removal is running for.
    @Published private(set) var working: AgentKind?
    /// What the install or removal is doing right now, shown in place of the status hint.
    @Published private(set) var step: String?
    @Published private(set) var errors: [AgentKind: String] = [:]

    @Published var claudeOn = AppPreferences.shared.agentKindEnabled(.claudeCode) {
        didSet { AppPreferences.shared.setAgentKind(.claudeCode, enabled: claudeOn) }
    }
    @Published var codexOn = AppPreferences.shared.agentKindEnabled(.codex) {
        didSet { AppPreferences.shared.setAgentKind(.codex, enabled: codexOn) }
    }
    @Published var piOn = AppPreferences.shared.agentKindEnabled(.pi) {
        didSet { AppPreferences.shared.setAgentKind(.pi, enabled: piOn) }
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

    /// The moments and projects only matter while some agent is answered. Codex counts only
    /// once its plugin is found: without it, Codex can't answer, so its switch is hidden and a
    /// stored codexOn mustn't keep this on by itself.
    var codexHasPlugin: Bool { codexStatus == .installed }

    var enabled: Bool { claudeOn || (codexOn && codexHasPlugin) || piOn }

    init() { refreshProjects() }

    #if DEBUG
    /// Set by `ui-snapshot`, which must not depend on whether this Mac has Codex.
    static var snapshotCodexStatus: CodexPlugin.Status?
    #endif

    func checkPlugins() async {
        status = await ClaudeCodePlugin.status()
        #if DEBUG
        if let staged = Self.snapshotCodexStatus { codexStatus = staged; return }
        #endif
        codexStatus = await CodexPlugin.status()
    }

    func install() { change(.claudeCode) { await ClaudeCodePlugin.install(step: $0) } }
    func uninstall() { change(.claudeCode) { await ClaudeCodePlugin.uninstall(step: $0) } }
    func installCodex() { change(.codex) { await CodexPlugin.install(step: $0) } }
    func uninstallCodex() { change(.codex) { await CodexPlugin.uninstall(step: $0) } }

    private func change(
        _ kind: AgentKind,
        _ action: @escaping (@escaping @MainActor (String) -> Void) async -> Result<Void, PluginError>
    ) {
        working = kind
        step = nil
        errors[kind] = nil
        Task {
            let result = await action { [weak self] in self?.step = $0 }
            working = nil
            step = nil
            if case .failure(let failure) = result { errors[kind] = failure.message }
            await checkPlugins()
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
