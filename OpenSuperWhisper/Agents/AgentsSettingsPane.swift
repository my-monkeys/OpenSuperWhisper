import SwiftUI

/// Settings › Agents: one section per agent (the plugin, and whether OpenSuperWhisper answers
/// for it), then which moments bring the panel up, how long it waits, and which projects use it.
struct AgentsSettingsPane: View {
    /// nil until the background check answers.
    @State private var status: ClaudeCodePlugin.Status?
    @State private var working = false
    /// What the install or removal is doing right now, shown in place of the status hint.
    @State private var step: String?
    @State private var error: String?

    @State private var claudeOn = AppPreferences.shared.agentKindEnabled(.claudeCode)
    @State private var codexOn = AppPreferences.shared.agentKindEnabled(.codex)
    @State private var codexHasPlugin = false
    /// The moments and projects only matter while some agent is answered.
    private var enabled: Bool { claudeOn || codexOn }
    @State private var askOnStop = AppPreferences.shared.agentAskOnStop
    @State private var askOnPermission = AppPreferences.shared.agentAskOnPermission
    @State private var askOnQuestion = AppPreferences.shared.agentAskOnQuestion
    @State private var waitSeconds = AppPreferences.shared.agentWaitSeconds
    @State private var projects = AgentsSettingsPane.listedProjects(
        recent: AppPreferences.shared.agentRecentProjects,
        disabled: AppPreferences.shared.agentDisabledProjects)
    @State private var disabledProjects = AppPreferences.shared.agentDisabledProjects

    var body: some View {
        SPane(title: "Agents", subtitle: "Answer coding agents by voice") {
            SSection(title: "Claude Code") {
                pluginRow
                if let error {
                    SWarnBox { Text(error).textSelection(.enabled) }
                }
                SRow(title: "Answer Claude Code",
                     hint: "Off, Claude Code waits in its terminal as if the plugin were not installed") {
                    SToggle(isOn: $claudeOn)
                }
            }

            SSection(title: "Codex") {
                HStack(spacing: 12) {
                    AgentAvatar(kind: .codex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(codexHasPlugin ? "Codex has the plugin" : "Codex doesn't have the plugin")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(STheme.text)
                        Text(codexHasPlugin
                             ? "Codex copies Claude Code's plugins on its own. It stays in its terminal until you turn it on here."
                             : "Codex picks up the plugin by itself once it is installed for Claude Code.")
                            .scaledFont(size: 11)
                            .foregroundColor(STheme.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                SRow(title: "Answer Codex",
                     hint: "Codex asks once to trust the plugin's hooks: run /hooks in Codex. Its questions stay in the terminal for now") {
                    SToggle(isOn: $codexOn)
                }
            }

            SSection(title: "Show the panel when the agent") {
                SRow(title: "Finishes a task", hint: "Its last message, and your answer becomes its next instruction") {
                    SToggle(isOn: $askOnStop, disabled: !enabled)
                }
                SRow(title: "Needs a permission", hint: "Allow or deny a command, a file edit, a fetch") {
                    SToggle(isOn: $askOnPermission, disabled: !enabled)
                }
                SRow(title: "Asks a question", hint: "Pick among its options, or answer in your own words") {
                    SToggle(isOn: $askOnQuestion, disabled: !enabled)
                }
                SRow(title: "Wait for an answer",
                     hint: "Then the agent goes back to its terminal, where you can still answer") {
                    Picker("", selection: $waitSeconds) {
                        ForEach(AppPreferences.agentWaitChoices, id: \.self) { seconds in
                            Text(Self.label(forWait: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // Its own width: a fixed 220 pt was narrower than four segments at the
                    // default text size, and "10 min" ran past the pane's right edge.
                    .fixedSize()
                    .disabled(!enabled)
                }
            }

            SSection(title: "Projects") {
                if projects.isEmpty {
                    Text("A project shows up here the first time one of its agents asks for you.")
                        .scaledFont(size: 11.5)
                        .foregroundColor(STheme.hint)
                } else {
                    ForEach(projects, id: \.self, content: projectRow)
                }
            }
        }
        .onAppear(perform: refresh)
        .task {
            status = await ClaudeCodePlugin.status()
            codexHasPlugin = CodexPlugin.isEnabled()
        }
        .onChange(of: claudeOn) { AppPreferences.shared.setAgentKind(.claudeCode, enabled: claudeOn) }
        .onChange(of: codexOn) { AppPreferences.shared.setAgentKind(.codex, enabled: codexOn) }
        .onChange(of: askOnStop) { AppPreferences.shared.agentAskOnStop = askOnStop }
        .onChange(of: askOnPermission) { AppPreferences.shared.agentAskOnPermission = askOnPermission }
        .onChange(of: askOnQuestion) { AppPreferences.shared.agentAskOnQuestion = askOnQuestion }
        .onChange(of: waitSeconds) { AppPreferences.shared.agentWaitSeconds = waitSeconds }
    }

    private var pluginRow: some View {
        HStack(spacing: 12) {
            AgentAvatar(kind: .claudeCode)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(STheme.text)
                Text(working ? (step ?? "Working…") : statusHint)
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if working {
                ProgressView().controlSize(.small)
            } else {
                switch status {
                case nil:
                    ProgressView().controlSize(.small)
                case .installed:
                    Button("Remove") { change { await ClaudeCodePlugin.uninstall(step: $0) } }
                        .controlSize(.small)
                case .notInstalled:
                    Button("Install the plugin") { change { await ClaudeCodePlugin.install(step: $0) } }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(STheme.accent)
                case .noClaudeCode:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch status {
        case nil: return "Claude Code"
        case .installed: return "Plugin installed"
        case .notInstalled: return "Plugin not installed"
        case .noClaudeCode: return "Claude Code not found"
        }
    }

    private var statusHint: String {
        switch status {
        case nil:
            return "Checking for the plugin…"
        case .installed:
            return "New Claude Code sessions use it. Restart the ones already open."
        case .notInstalled:
            return "Adds the OpenSuperWhisper plugin to Claude Code, through its own plugin command."
        case .noClaudeCode:
            return "Install Claude Code, then come back here to add the plugin."
        }
    }

    private func change(
        _ action: @escaping (@escaping @MainActor (String) -> Void) async -> Result<Void, ClaudeCodePlugin.PluginError>
    ) {
        working = true
        step = nil
        error = nil
        Task {
            let result = await action { step = $0 }
            working = false
            step = nil
            if case .failure(let failure) = result { error = failure.message }
            status = await ClaudeCodePlugin.status()
        }
    }

    private func refresh() {
        disabledProjects = AppPreferences.shared.agentDisabledProjects
        projects = Self.listedProjects(recent: AppPreferences.shared.agentRecentProjects,
                                       disabled: disabledProjects)
    }

    private func projectRow(_ path: String) -> some View {
        let parent = Self.folderTurningOff(path, disabled: disabledProjects)
        let coveredInside = Self.projectsOnlyTurnedOff(by: path, among: projects, disabled: disabledProjects)
        return VStack(alignment: .leading, spacing: 2) {
            SRow(title: LocalizedStringKey(URL(fileURLWithPath: path).lastPathComponent),
                 hint: LocalizedStringKey(Self.abbreviated(path))) {
                // Under a turned-off folder the switch stays put, even when the project is also
                // off on its own: the folder's rule covers everything below it, turning the
                // folder on from here would also turn on its other projects without saying so,
                // and turning this one on would change nothing until the folder is back on.
                SToggle(isOn: projectBinding(path), disabled: !enabled || parent != nil)
            }
            if let parent {
                caption("Off because it is inside \(Self.abbreviated(parent)), which is off. Turn that folder back on to use the panel here.",
                        color: STheme.warn)
            } else if coveredInside > 0 {
                caption(coveredInside == 1
                        ? "Also turns off 1 project inside it."
                        : "Also turns off \(coveredInside) projects inside it.",
                        color: STheme.hint)
            }
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 11)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func projectBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { AppPreferences.agentProjectTurnedOff(path, by: disabledProjects) == nil },
            set: { on in
                AppPreferences.shared.setAgentProject(path, enabled: on)
                disabledProjects = AppPreferences.shared.agentDisabledProjects
            })
    }

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
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
