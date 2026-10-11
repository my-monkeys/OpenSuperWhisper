import SwiftUI
import OpenSuperWhisperCore

/// The global switches behind the per-app list: whether model rules apply, whether per-app
/// formatting runs, and the default typing pace.
struct StyleRulesGroup: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// Context-aware model selection only makes sense with two or more usable models.
    let hasModelChoice: Bool

    var body: some View {
        SettingsGroup("Rules") {
            if hasModelChoice {
                SettingRow("Model switching",
                           hint: "When the front app changes. Bind a model to an app below, or from the menu-bar “Model” submenu.") {
                    HStack(spacing: 8) {
                        InfoButton(text: "• Ask on change: switch by app, and ask the scope (system default, this app, just once, forget) whenever you pick a model in the menu.\n• Auto · no prompt: switch by app, but picking a model in the menu just sets the system default.\n• Off: no automatic switch and no prompts.")
                        SPicker(selection: $viewModel.contextAwareModelMode,
                                options: ContextAwareModelMode.allCases.map { ($0, LocalizedStringKey($0.label)) })
                    }
                }
            } else {
                SettingNotice("Model rules need at least two models to switch between. Formatting and insertion rules work with one.") {
                    Button("Open Models") { AppNavigation.shared.openSettings(.models) }
                        .buttonStyle(.sSecondary)
                }
            }
            SettingRow("Reformat per app",
                       hint: "Reshape the text through AI cleanup, based on the app you dictate into, such as “at Rob” → “@Rob” in Slack. Uses the AI cleanup backend set in Settings → Text & AI.") {
                SSwitch(isOn: $viewModel.appContextFormattingEnabled)
            }
            SettingRow("Typing pace",
                       hint: "Milliseconds between keystroke bursts. Raise it if dictating into a busy input box duplicates or misplaces text; the cost is a slower insertion.") {
                Stepper(value: $viewModel.typingPaceMilliseconds,
                        in: 0...TextInserter.maxChunkPauseMilliseconds) {
                    Text(verbatim: "\(viewModel.typingPaceMilliseconds) ms")
                        .scaledFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundColor(STheme.textSecondary)
                }
                .fixedSize()
            }
        }
    }
}
