import SwiftUI
import OpenSuperWhisperCore

/// Hints given to the speech model before it listens. Every row is a fine-tuning, so the group
/// only appears with Advanced on.
struct TextAIRecognitionGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Recognition", advanced: true) {
            SettingRow("Instructions for the model",
                       hint: promptHint,
                       badge: viewModel.initialPrompt.isEmpty ? nil : ("Customized", .custom),
                       advanced: true, stacked: true) {
                TextAIEditor(text: $viewModel.initialPrompt,
                             placeholder: "Product meeting, terms: sprint, backlog, PR.")
                    .disabled(!viewModel.canUsePrompt)
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

    private var promptHint: LocalizedStringKey {
        viewModel.canUsePrompt
            ? "Words or style the model should expect. Whisper copies its style, so a few lines of your own writing teach it your punctuation. A file at ~/.config/opensuperwhisper/prompt.md replaces this box when it exists."
            : "Only Whisper and a remote server read these instructions. The current engine has nowhere to put them; your dictionary is how to teach it words."
    }

    /// Saying why the switch is off matters more than describing it: a switch that flips and
    /// changes nothing is the mistake of #99. The mode carries both halves — what the engine does
    /// with the text, and the two different reasons it may do nothing with it. The two disabled
    /// sentences say why, not which engine: `.none` is no input, `.remoteExcluded` is an input the
    /// text must never reach.
    private var fieldContextHint: LocalizedStringKey {
        switch EngineCapabilities.fieldContextMode(for: viewModel.selectedEngine) {
        case .prose:
            return "Reads the focused field to recognise names better. The field text is never sent as context, but a recognised word can end up in your transcript, which goes to your AI engine when cleanup runs."
        case .terms:
            return "Reads the focused field and gives Parakeet a term list from it, not a sentence. The field text is never sent as context, but a word that sounds close to a listed term can be rewritten into your transcript, which goes to your AI engine when cleanup runs."
        case .none:
            return "This engine takes no hint about what is coming, so the field is not read."
        case .remoteExcluded:
            return "Never: this text would be sent to your server, so the field is not read."
        }
    }
}
