import SwiftUI
import OpenSuperWhisperCore

/// Names a style and says, in plain words, how AI cleanup should write in it.
struct WritingStyleEditor: View {
    let isNew: Bool
    let onSave: (WritingStyle) -> Void
    let onDelete: (WritingStyle) -> Void
    @State private var style: WritingStyle
    @Environment(\.dismiss) private var dismiss

    /// Long enough for a tone, a spelling variant and a few terms; a small model loses track of
    /// the dictation itself past that.
    static let instructionsLimit = 600

    init(style: WritingStyle, isNew: Bool,
         onSave: @escaping (WritingStyle) -> Void, onDelete: @escaping (WritingStyle) -> Void) {
        self._style = State(initialValue: style)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var trimmedName: String { style.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { style.instructions.count > Self.instructionsLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New style" : "Edit style")
                .scaledFont(size: 19, weight: .bold)
                .foregroundColor(STheme.textBright)
            field("Name") {
                STextField("Work, Charity, Family…", text: $style.name, width: nil)
            }
            field("How to write") {
                SEditor(text: $style.instructions, height: 130, fontSize: 13, monospaced: false,
                        placeholder: "Friendly and encouraging, plain British English. Say “volunteers”, never “staff”. Keep every fact as said.")
                Text(tooLong
                     ? "Shorter instructions work better, especially with small models."
                     : "Added to the AI cleanup instruction. Describe the tone, the spelling and the words to use.")
                    .scaledFont(size: 12)
                    .foregroundColor(tooLong ? STheme.accent : STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if !isNew {
                    Button("Delete style", role: .destructive) { onDelete(style) }
                        .buttonStyle(.sDanger)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    style.name = trimmedName
                    onSave(style)
                }
                .buttonStyle(.sPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(STheme.cardBg)
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.textBright)
            content()
        }
    }
}
