import SwiftUI
import OpenSuperWhisperCore

/// The modal editor behind a dictionary row.
///
/// It edits a local copy and hands it back on Save. Editing through a binding into the array
/// resolves the row again on every keystroke, which traps once the row is deleted while a field
/// is still open (the reason the old badge editor worked on a copy too).
struct DictionaryEntryEditor: View {
    let isNew: Bool
    let onSave: (CustomDictionaryEntry) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    private enum EntryType { case word, correction }

    @State private var draft: CustomDictionaryEntry
    @State private var type: EntryType
    @State private var newVariant = ""
    @State private var sample: String
    @FocusState private var variantFieldFocused: Bool

    init(initial: CustomDictionaryEntry, isNew: Bool,
         onSave: @escaping (CustomDictionaryEntry) -> Void,
         onDelete: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        // Blank phrasings dropped up front, so chip positions match `removeTrigger(at:)`.
        var normalized = initial
        let triggers = initial.triggers
        normalized.original = triggers.first ?? ""
        normalized.alternates = Array(triggers.dropFirst())
        _draft = State(initialValue: normalized)
        _type = State(initialValue: !isNew && initial.kind == .word ? .word : .correction)
        _sample = State(initialValue: Self.sampleSentence(for: initial))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                form
                ScrollView { form }
            }
            footer
        }
    }

    // MARK: - Layout

    private var header: some View {
        HStack {
            Text(isNew ? "New entry" : "Edit entry")
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(STheme.textBright)
            Spacer(minLength: 0)
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            typeCards
            alwaysWriteField
            if type == .correction {
                variantsField
            }
            options
            DictionaryTestBox(sample: $sample, entry: result)
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                Button("Delete", action: onDelete)
                    .buttonStyle(.sDanger)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onClose)
                .buttonStyle(.sSecondary)
            Button("Save") { onSave(result) }
                .buttonStyle(.sPrimary)
                .disabled(!isValid)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var typeCards: some View {
        HStack(alignment: .top, spacing: 10) {
            typeCard(.word, symbol: "textformat", title: "New word",
                     detail: "A name or term to recognise better.")
            typeCard(.correction, symbol: "arrow.left.arrow.right", title: "Correction",
                     detail: "Replace what the model writes.")
        }
        // Both cards as tall as the taller one, and no taller.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func typeCard(_ value: EntryType, symbol: String, title: LocalizedStringKey,
                          detail: LocalizedStringKey) -> some View {
        let selected = type == value
        return Button { type = value } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(selected ? STheme.accent : STheme.textBright)
                Text(detail)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? STheme.accentTint : STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var alwaysWriteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Always write")
            TextField("", text: $draft.replacement,
                      prompt: Text(draft.isRegex && type == .correction ? "“$1,” said $2" : "My-Monkey"))
                .textFieldStyle(.plain)
                .scaledFont(size: 16, weight: .semibold,
                            design: draft.isRegex && type == .correction ? .monospaced : .default)
                .foregroundColor(STheme.textBright)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
        }
    }

    private var variantsField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(draft.isRegex ? "When it matches" : "When the model writes")
            FlowLayout(spacing: 8) {
                ForEach(Array(draft.triggers.enumerated()), id: \.offset) { position, trigger in
                    variantChip(trigger, at: position)
                }
                TextField("", text: $newVariant,
                          prompt: Text(draft.isRegex ? "Add a pattern…" : "Add a variant…"))
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14, design: draft.isRegex ? .monospaced : .default)
                    .foregroundColor(STheme.textBright)
                    .focused($variantFieldFocused)
                    .onSubmit(addVariant)
                    .frame(minWidth: 160)
                    .padding(.vertical, 5)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { variantFieldFocused = true }
            Text(draft.isRegex
                 ? "Regular expressions. Write $1, $2… in “Always write” to reuse what they capture. Enter to add."
                 : "Several variants can point to the same word. Enter to add. \\n = line break.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            if let invalid = invalidPattern {
                Text("This pattern is not a valid regular expression: \(invalid)")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(STheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func variantChip(_ text: String, at position: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: text)
                .scaledFont(size: 14, design: draft.isRegex ? .monospaced : .default)
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { draft.removeTrigger(at: position) } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundColor(STheme.hint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this variant")
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(STheme.fill))
    }

    /// The existing advanced options of the old rule editor, plus the per-entry options the
    /// design shows but the engine does not have yet.
    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            if type == .correction {
                EditorOptionRow("Regex", hint: "Match with a regular expression and use $1, $2… in the result.") {
                    SSwitch(isOn: $draft.isRegex)
                }
                // A regex says for itself what it consumes, so a spacing choice would be a
                // second, contradictory answer to the same question.
                if !draft.isRegex {
                    EditorOptionRow("Spacing", hint: "For punctuation: Opens glues to the next word, Closes to the previous one.") {
                        SSegmented(selection: $draft.spacing, options: [
                            (.standalone, "Keep spaces"),
                            (.attachesRight, "Opens"),
                            (.attachesLeft, "Closes"),
                        ])
                    }
                }
                EditorOptionRow("Whole word only",
                                hint: draft.isRegex
                                    ? "A pattern sets its own boundaries."
                                    : "Always on: a variant never matches inside a longer word.") {
                    SSwitch(isOn: .constant(!draft.isRegex))
                        .disabled(true)
                }
            }
            EditorOptionRow("Also help recognition of this word",
                            hint: "For now this follows “Help recognition of these words”, for every entry.",
                            soon: true) {
                SSwitch(isOn: .constant(false))
            }
            EditorOptionRow("Applies", soon: true) {
                SMenu(Text("Everywhere")) { EmptyView() }
            }
        }
        .background(STheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.textBright)
    }

    // MARK: - Logic

    /// The entry Save would store. A new word is stored as a rule whose only trigger is the word
    /// itself: it rewrites nothing and feeds the recognition boost, in the existing format.
    private var result: CustomDictionaryEntry {
        var entry = draft
        entry.replacement = draft.trimmedReplacement
        switch type {
        case .word:
            entry.original = entry.replacement
            entry.alternates = []
            entry.isRegex = false
            entry.spacing = .standalone
        case .correction:
            var triggers = draft.triggers
            let pending = newVariant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pending.isEmpty && !contains(pending, in: triggers) { triggers.append(pending) }
            entry.original = triggers.first ?? ""
            entry.alternates = Array(triggers.dropFirst())
        }
        return entry
    }

    private var isValid: Bool {
        let entry = result
        guard !entry.replacement.isEmpty else { return false }
        guard type == .correction else { return true }
        return !entry.triggers.isEmpty && invalidPattern == nil
    }

    private var invalidPattern: String? {
        guard type == .correction, draft.isRegex else { return nil }
        return result.triggers.first { (try? NSRegularExpression(pattern: $0)) == nil }
    }

    private func addVariant() {
        let variant = newVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        newVariant = ""
        variantFieldFocused = true
        guard !variant.isEmpty, !contains(variant, in: draft.triggers) else { return }
        if draft.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.original = variant
        } else {
            draft.alternates.append(variant)
        }
        if sample.isEmpty || draft.triggers.count == 1 {
            sample = Self.sampleSentence(for: draft)
        }
    }

    private func contains(_ variant: String, in triggers: [String]) -> Bool {
        triggers.contains { $0.caseInsensitiveCompare(variant) == .orderedSame }
    }

    /// A sentence the entry is likely to bite on. A regex cannot be turned back into text, so a
    /// fixed line of dialogue stands in: it is the case regex rules were added for.
    private static func sampleSentence(for entry: CustomDictionaryEntry) -> String {
        if entry.isRegex { return "Not tonight, said Frank." }
        let spoken = entry.triggers.first ?? entry.trimmedReplacement.lowercased()
        guard !spoken.isEmpty else { return "" }
        return String(localized: "I talked to \(spoken) yesterday")
    }
}

/// A compact settings row for the editor's option card: the modal has less room than a
/// settings page, so rows are tighter than `SettingRow`.
private struct EditorOptionRow<Control: View>: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var soon = false
    @ViewBuilder var control: () -> Control

    init(_ title: LocalizedStringKey, hint: LocalizedStringKey? = nil, soon: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.hint = hint
        self.soon = soon
        self.control = control
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundColor(soon ? STheme.hint : STheme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                    if soon { SoonBadge() }
                }
                if let hint {
                    Text(hint)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            control()
                .disabled(soon)
                .opacity(soon ? 0.5 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}
