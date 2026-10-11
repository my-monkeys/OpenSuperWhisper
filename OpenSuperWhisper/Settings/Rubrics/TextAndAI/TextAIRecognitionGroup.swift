import SwiftUI
import OpenSuperWhisperCore

/// Hints given to the speech model before it listens. Every row is a fine-tuning, so the group
/// only appears with Advanced on.
struct TextAIRecognitionGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Recognition", advanced: true) {
            SettingRow("Instructions for the model",
                       hint: "Words or style the model should expect. Whisper copies its style, so a few lines of your own writing teach it your punctuation. A file at ~/.config/opensuperwhisper/prompt.md replaces this box when it exists.",
                       badge: viewModel.initialPrompt.isEmpty ? nil : ("Customized", .custom),
                       advanced: true, stacked: true) {
                TextAIEditor(text: $viewModel.initialPrompt,
                             placeholder: "Product meeting, terms: sprint, backlog, PR.")
            }
            SettingRow("Use the text around the cursor", hint: fieldContextHint, advanced: true) {
                SSwitch(isOn: $viewModel.useSurroundingTextAsContext)
                    .disabled(!viewModel.canUseFieldContext)
            }
            if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                SettingRow("Chinese, Japanese and Korean spacing",
                           hint: "Fixes the spacing in CJK text. Shown only for these languages.",
                           advanced: true) {
                    SSwitch(isOn: $viewModel.useAsianAutocorrect)
                }
            }
        }
    }

    /// Saying why the switch is off matters more than describing it: a switch that flips and
    /// changes nothing is the mistake of #99.
    private var fieldContextHint: LocalizedStringKey {
        viewModel.canUseFieldContext
            ? "Reads the focused field to recognise names better. Never sent to a server."
            : "Only Whisper can be told what to expect. The current engine has nowhere to put it."
    }
}
