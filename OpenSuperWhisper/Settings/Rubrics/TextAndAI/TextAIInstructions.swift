import SwiftUI
import OpenSuperWhisperCore

/// The cleanup instruction: two halves the user owns, with the matching per-app rule from Style
/// sandwiched between them, and nothing else wrapped around either.
///
/// The opening belongs to general cleanup and goes with it. The closing reaches every pass,
/// including one an app rule started on its own, so it stays visible either way: it carries the
/// guardrail, and a field that shapes someone's output has to be one they can read.
struct TextAIInstructions: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        if viewModel.aiPostProcessingEnabled {
            promptRow("Opening instruction",
                      hint: "Any matching per-app rule from Style is inserted after it.",
                      half: .opening,
                      text: $viewModel.aiPostProcessingPrompt,
                      defaultText: LLMPostProcessor.defaultInstruction,
                      height: 110)
        }
        if viewModel.translateToEnglish {
            translationRow
        }
        promptRow("Closing instruction",
                  hint: nil,
                  half: .closing,
                  text: $viewModel.aiPostProcessingClosing,
                  defaultText: LLMPostProcessor.defaultClosingInstruction,
                  height: 56)
        TextAILine(advanced: true) { TextAIFootnote(explanation) }
        failureLine
    }

    private var explanation: LocalizedStringKey {
        viewModel.aiPostProcessingEnabled
            ? "Together these two are the entire system prompt, nothing is added around them. The closing half stays the model's last word, after any app rule. A small model tends to answer in the language the prompt is written in, so write it in the language you dictate."
            : "Sent after your per-app rules from Style, as the model's last word. It is the only thing standing between a dictated question and a model that answers it, so keep something in it. A small model tends to answer in the language the prompt is written in, so write it in the language you dictate."
    }

    @ViewBuilder private var failureLine: some View {
        switch viewModel.promptTranslationFailure {
        case .backendUnavailable:
            TextAILine(advanced: true) {
                TextAIFootnote("Couldn't reach the cleanup engine. Check its settings above.", color: STheme.warn)
            }
        case .unusableOutput:
            TextAILine(advanced: true) {
                TextAIFootnote("The model didn't return a usable translation, so your text was kept. Small models struggle with this; Ollama or a remote model handles it reliably.",
                               color: STheme.warn)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: Rows

    private func promptRow(_ title: String,
                           hint: LocalizedStringKey?,
                           half: SettingsViewModel.PromptHalf,
                           text: Binding<String>,
                           defaultText: String,
                           height: CGFloat) -> some View {
        SettingRow(title, hint: hint,
                   badge: text.wrappedValue == defaultText ? nil : ("Customized", .custom),
                   advanced: true, stacked: true) {
            VStack(alignment: .leading, spacing: 8) {
                TextAIEditor(text: text, height: height)
                actions(half: half, text: text, defaultText: defaultText)
            }
        }
    }

    /// Translate stays enabled while a translation runs: a second click queues rather than being
    /// swallowed, and the spinner appears the moment a half is queued. Undo is always present,
    /// like Reset, so the buttons never jump around between the two halves.
    private func actions(half: SettingsViewModel.PromptHalf,
                         text: Binding<String>,
                         defaultText: String) -> some View {
        // Three buttons in German already outgrew the narrowest window: they stack when needed.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(half: half, text: text, defaultText: defaultText) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(half: half, text: text, defaultText: defaultText) }
        }
    }

    @ViewBuilder
    private func actionButtons(half: SettingsViewModel.PromptHalf,
                               text: Binding<String>,
                               defaultText: String) -> some View {
        Button("Undo") { viewModel.undoPromptTranslation(half) }
            .buttonStyle(.sSecondary)
            .disabled(viewModel.promptBeforeTranslation[half] == nil)
        if let target = viewModel.promptTranslationTarget {
            Button("Translate to \(target)") { viewModel.translatePrompt(half) }
                .buttonStyle(.sSecondary)
        }
        Button("Reset to default") { text.wrappedValue = defaultText }
            .buttonStyle(.sDanger)
            .disabled(text.wrappedValue == defaultText)
        // Keeps its footprint whether or not it spins, so the row never reflows mid-translation.
        ZStack {
            if viewModel.isTranslating(half) {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var translationRow: some View {
        let isDefault = viewModel.aiPostProcessingTranslation == LLMPostProcessor.defaultTranslationInstruction
        return SettingRow("When translating",
                          hint: "Sent only while Translate to English is on, so instructions about translating never reach a dictation that isn't one. Whisper's own translation reads literally; this is where you ask for the English a fluent speaker would use.",
                          badge: isDefault ? nil : ("Customized", .custom),
                          advanced: true, stacked: true) {
            VStack(alignment: .leading, spacing: 8) {
                TextAIEditor(text: $viewModel.aiPostProcessingTranslation, height: 72)
                Button("Reset to default") {
                    viewModel.aiPostProcessingTranslation = LLMPostProcessor.defaultTranslationInstruction
                }
                .buttonStyle(.sDanger)
                .disabled(isDefault)
            }
        }
    }
}
