import SwiftUI
import OpenSuperWhisperCore

/// Settings › Assistants: the Claude Code plugin and Codex, the moments that bring the answer
/// panel up, and how the panel behaves. Ported from the old Agents pane.
struct AssistantsRubric: View {
    @StateObject private var model = AssistantsSettingsModel()
    @State private var managingProjects = false

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "Claude Code", rubric: .assistants,
              keywords: "claude code plugin install remove agent installer désinstaller extension"),
        .init(title: "Answer Claude Code", rubric: .assistants,
              keywords: "claude code agent répondre panneau"),
        .init(title: "Codex", rubric: .assistants,
              keywords: "codex openai plugin hooks agent"),
        .init(title: "Answer Codex", rubric: .assistants,
              keywords: "codex agent répondre panneau hooks"),
        .init(title: "Finishes a task", rubric: .assistants,
              keywords: "notifications stop done agent tâche terminée prévenir"),
        .init(title: "Needs a permission", rubric: .assistants,
              keywords: "notifications permission allow deny autorisation prévenir"),
        .init(title: "Asks a question", rubric: .assistants,
              keywords: "notifications question voice prévenir question voix"),
        .init(title: "Notification sound", rubric: .assistants, advanced: true,
              keywords: "sound notifications son alerte"),
        .init(title: "Followed projects", rubric: .assistants, advanced: true,
              keywords: "projects folders projets dossiers suivis claude codex"),
        .init(title: "Answer by voice", rubric: .assistants, advanced: true,
              keywords: "voice shortcut dictation répondre à la voix raccourci"),
        .init(title: "Panel position", rubric: .assistants, advanced: true,
              keywords: "panel position corner panneau position coin"),
        .init(title: "Wait for an answer", rubric: .assistants,
              keywords: "timeout wait delay attendre délai réponse fermer après"),
    ]

    var body: some View {
        RubricPage(.assistants, intro: "Dictate your answers to Claude Code and Codex, and hear when they are waiting.") {
            connectionsGroup
            notifyGroup
            panelGroup
        }
        .overlay {
            if managingProjects {
                FollowedProjectsCard(model: model) { managingProjects = false }
            }
        }
        .onAppear(perform: model.refreshProjects)
        .task { await model.checkPlugins() }
    }

    // MARK: Connections

    private var connectionsGroup: some View {
        SettingsGroup("Connections") {
            SettingRow("Claude Code", hint: claudeHint) {
                claudeControl
            }
            if let error = model.error {
                AssistantsErrorRow(message: error)
            }
            SettingRow("Answer Claude Code",
                       hint: "Off, Claude Code waits in its terminal as if the plugin were not installed.",
                       indented: true) {
                SSwitch(isOn: $model.claudeOn)
            }
            SettingRow("Codex", hint: model.codexHasPlugin
                       ? "Plugin found. Codex copies Claude Code's plugins on its own."
                       : "Codex picks up the plugin by itself once it is installed for Claude Code.") {
                if model.codexHasPlugin {
                    StatusPill(text: "✓ Plugin found")
                }
            }
            SettingRow("Answer Codex",
                       hint: "Codex asks once to trust the plugin's hooks: run /hooks in Codex.",
                       indented: true) {
                SSwitch(isOn: $model.codexOn)
            }
            SettingNotice("Codex's questions still show in the terminal, not in the panel.")
        }
    }

    private var claudeHint: LocalizedStringKey {
        if model.working { return LocalizedStringKey(model.step ?? "Working…") }
        switch model.status {
        case nil: return "Checking for the plugin…"
        case .installed: return "Plugin installed. New sessions use it; restart the ones already open."
        case .notInstalled: return "Adds the OpenSuperWhisper plugin to Claude Code, through its own plugin command."
        case .noClaudeCode: return "Claude Code not found. Install it, then come back here to add the plugin."
        }
    }

    @ViewBuilder private var claudeControl: some View {
        if model.working || model.status == nil {
            ProgressView().controlSize(.small)
        } else {
            switch model.status {
            case .installed:
                HStack(spacing: 8) {
                    StatusPill(text: "✓ Connected")
                    Button("Remove", action: model.uninstall)
                        .buttonStyle(.sDanger)
                }
            case .notInstalled:
                Button("Install the plugin", action: model.install)
                    .buttonStyle(.sPrimary)
            case .noClaudeCode, nil:
                EmptyView()
            }
        }
    }

    // MARK: Notify me when

    private var notifyGroup: some View {
        SettingsGroup("Notify me when") {
            if !model.enabled {
                SettingNotice("Turn on Claude Code or Codex above to choose when the panel shows.")
            }
            Group {
                SettingRow("Finishes a task") { SSwitch(isOn: $model.askOnStop) }
                SettingRow("Needs a permission") { SSwitch(isOn: $model.askOnPermission) }
                SettingRow("Asks a question", hint: "You can answer by voice from the panel.") {
                    SSwitch(isOn: $model.askOnQuestion)
                }
            }
            .disabled(!model.enabled)
            SettingRow("Notification sound", advanced: true, soon: true) {
                SMenu(Text("Glass")) { EmptyView() }
            }
            SettingRow("Followed projects", hint: LocalizedStringKey(model.projectsSummary), advanced: true) {
                Button("Manage…") {
                    model.refreshProjects()
                    managingProjects = true
                }
                .buttonStyle(.sSecondary)
            }
        }
    }

    // MARK: Answer panel

    private var panelGroup: some View {
        SettingsGroup("Answer panel") {
            SettingRow("Answer by voice", hint: "Your dictation shortcut, while the panel is open.", advanced: true) {
                SKeyCap(dictationTrigger)
            }
            SettingRow("Panel position", advanced: true, soon: true) {
                SMenu(Text("Top right")) { EmptyView() }
            }
            SettingRow("Wait for an answer",
                       hint: "Then the agent goes back to its terminal, where you can still answer.") {
                SPicker(selection: $model.waitSeconds,
                        options: AppPreferences.agentWaitChoices.map {
                            ($0, LocalizedStringKey(AgentSettings.label(forWait: $0)))
                        })
                .disabled(!model.enabled)
            }
        }
    }

    /// The first recording trigger: the same key starts a reply while the panel has focus.
    private var dictationTrigger: String {
        let prefs = AppPreferences.shared
        let trigger = RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers.first
            ?? RecordingTriggerSet.load(from: prefs.holdRecordingTriggers).triggers.first
        guard let caps = trigger?.caps, !caps.isEmpty else { return String(localized: "Not set") }
        return caps.joined(separator: " ")
    }
}

/// A state that is already good, drawn like the green button but not clickable.
private struct StatusPill: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.ok)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.okBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.okBorder, lineWidth: 1))
            .fixedSize()
    }
}

/// What the plugin command said when an install or removal failed, selectable for a bug report.
private struct AssistantsErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 13)
                .foregroundColor(STheme.warn)
            Text(verbatim: message)
                .scaledFont(size: 13)
                .foregroundColor(STheme.warn)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(STheme.warnBg)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}
