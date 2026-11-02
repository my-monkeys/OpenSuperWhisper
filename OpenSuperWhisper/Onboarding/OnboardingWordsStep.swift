import SwiftUI

/// Step 3: the words the user says every day, typed as chips. Optional: Continue writes them to
/// the dictionary, Skip writes nothing.
struct OnboardingWordsStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @FocusState private var fieldFocused: Bool

    private static let prompt: LocalizedStringKey = "Type a word, then press Return"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            field
            if let suggestion = viewModel.suggestedWord {
                suggestionRow(suggestion)
            }
            if !viewModel.words.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(viewModel.words, id: \.self) { chip($0) }
                }
            }
            examples
            OnboardingCallout {
                Text("Optional. You can add, change or remove words later in the Dictionary.")
            }
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var field: some View {
        HStack(spacing: 10) {
            TextField(text: $viewModel.wordDraft,
                      prompt: Text(Self.prompt).foregroundColor(STheme.faint)) { Text(Self.prompt) }
                .textFieldStyle(.plain)
                .scaledFont(size: 16)
                .foregroundColor(STheme.textBright)
                .focused($fieldFocused)
                .onSubmit {
                    viewModel.addWordDraft()
                    fieldFocused = true
                }
                .disabled(viewModel.wordLimitReached)
            Image(systemName: "return")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(STheme.hint)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(fieldFocused ? STheme.accent : STheme.border, lineWidth: fieldFocused ? 2 : 1))
    }

    private func suggestionRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Text("Your name?")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
            Button { viewModel.addWord(name) } label: {
                Label { Text(verbatim: name) } icon: { Image(systemName: "plus") }
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundColor(STheme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(STheme.accent.opacity(0.5),
                                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.wordLimitReached)
        }
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: word)
                .scaledFont(size: 14, weight: .medium)
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { viewModel.removeWord(word) } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundColor(STheme.hint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this word")
            .accessibilityLabel(Text("Remove \(word)"))
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
        .background(Capsule().fill(STheme.accentSoft))
    }

    private var examples: some View {
        Text("For example: Figma, Kubernetes, Marie-Claire, Villeurbanne.")
            .scaledFont(size: 13)
            .foregroundColor(STheme.hint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
