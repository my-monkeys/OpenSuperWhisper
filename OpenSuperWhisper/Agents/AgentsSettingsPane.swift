import SwiftUI

/// Settings › Agents: the Claude Code plugin, which moments bring the panel up, how long it
/// waits, and which projects use it.
struct AgentsSettingsPane: View {
    /// nil until the background check answers.
    @State private var status: ClaudeCodePlugin.Status?
    @State private var working = false
    /// What the install or removal is doing right now, shown in place of the status hint.
    @State private var step: String?
    @State private var error: String?

    @State private var enabled = AppPreferences.shared.agentsEnabled
    @State private var askOnStop = AppPreferences.shared.agentAskOnStop
    @State private var askOnPermission = AppPreferences.shared.agentAskOnPermission
    @State private var askOnQuestion = AppPreferences.shared.agentAskOnQuestion
    @State private var waitSeconds = AppPreferences.shared.agentWaitSeconds
    @State private var projects = AppPreferences.shared.agentRecentProjects
    @State private var disabledProjects = Set(AppPreferences.shared.agentDisabledProjects)

    var body: some View {
        SPane(title: "Agents", subtitle: "Answer coding agents by voice") {
            SSection(title: "Claude Code") {
                pluginRow
                if let error {
                    SWarnBox { Text(error).textSelection(.enabled) }
                }
                SRow(title: "Answer from OpenSuperWhisper",
                     hint: "Off, agents wait in their terminal as if the plugin were not installed") {
                    SToggle(isOn: $enabled)
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
                    .frame(width: 220)
                    .disabled(!enabled)
                }
            }

            SSection(title: "Projects") {
                if projects.isEmpty {
                    Text("A project shows up here the first time one of its agents asks for you.")
                        .scaledFont(size: 11.5)
                        .foregroundColor(STheme.hint)
                } else {
                    ForEach(projects, id: \.self) { path in
                        SRow(title: LocalizedStringKey(URL(fileURLWithPath: path).lastPathComponent),
                             hint: LocalizedStringKey(Self.abbreviated(path))) {
                            SToggle(isOn: projectBinding(path), disabled: !enabled)
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .task { status = await ClaudeCodePlugin.status() }
        .onChange(of: enabled) { AppPreferences.shared.agentsEnabled = enabled }
        .onChange(of: askOnStop) { AppPreferences.shared.agentAskOnStop = askOnStop }
        .onChange(of: askOnPermission) { AppPreferences.shared.agentAskOnPermission = askOnPermission }
        .onChange(of: askOnQuestion) { AppPreferences.shared.agentAskOnQuestion = askOnQuestion }
        .onChange(of: waitSeconds) { AppPreferences.shared.agentWaitSeconds = waitSeconds }
    }

    private var pluginRow: some View {
        HStack(spacing: 12) {
            AgentAvatar()
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
        projects = AppPreferences.shared.agentRecentProjects
        disabledProjects = Set(AppPreferences.shared.agentDisabledProjects)
    }

    private func projectBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { !disabledProjects.contains(path) },
            set: { on in
                AppPreferences.shared.setAgentProject(path, enabled: on)
                disabledProjects = Set(AppPreferences.shared.agentDisabledProjects)
            })
    }

    static func label(forWait seconds: Int) -> String {
        seconds >= 590 ? "10 min" : "\(seconds / 60) min"
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
