import SwiftUI
import OpenSuperWhisperCore

/// The custom dictionary: words the model should know and corrections to what it writes, one row
/// per written form. Edits go through a modal editor working on a copy, and land in
/// `viewModel.customDictionaryEntries` only on Save.
struct DictionaryPage: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var filter: DictionaryFilter = .all
    /// The entry open in the editor: an existing one, or a fresh one not yet in the list.
    @State private var editing: CustomDictionaryEntry?
    @State private var showPunctuationCalibration = false

    #if DEBUG
    /// Lets the snapshot renderer show the editor open on the first entry.
    static var snapshotOpensFirstEntry = false
    #endif

    private var entries: [CustomDictionaryEntry] { viewModel.customDictionaryEntries }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Dictionary",
                           subtitle: "Names and terms you say often. OpenSuperWhisper recognises them better and writes them the way you want.") {
                    Button {
                        editing = CustomDictionaryEntry()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.sPrimary)
                }
                DictionaryOptionsGroup(viewModel: viewModel,
                                       hasWords: entries.contains { $0.kind == .word },
                                       onTeachPunctuation: { showPunctuationCalibration = true })
                filterChips
                DictionaryEntryList(entries: entries.filter(filter.includes),
                                    dimmed: !viewModel.customDictionaryEnabled,
                                    emptyMessage: emptyMessage,
                                    onEdit: { editing = $0 },
                                    onDelete: delete)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if let entry = editing {
                ModalCard(maxWidth: 600, maxHeight: 900, onClose: { editing = nil }) {
                    DictionaryEntryEditor(
                        initial: entry,
                        isNew: !entries.contains { $0.id == entry.id },
                        onSave: save,
                        onDelete: { delete(entry); editing = nil },
                        onClose: { editing = nil })
                }
                .id(entry.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: editing?.id)
        .sheet(isPresented: $showPunctuationCalibration) {
            PunctuationCalibrationView(
                onFinish: { learned in
                    viewModel.customDictionaryEntries.append(contentsOf: learned)
                    showPunctuationCalibration = false
                },
                onCancel: { showPunctuationCalibration = false })
            .environment(\.appTextScale, viewModel.textScale)
        }
        .onAppear(perform: openSnapshotEditorIfAsked)
    }

    private var filterChips: some View {
        FlowLayout(spacing: 10) {
            chip(.all, title: "All", count: entries.count)
            chip(.words, title: "Words", count: entries.filter { $0.kind == .word }.count)
            chip(.corrections, title: "Corrections", count: entries.filter { $0.kind != .word }.count)
            // Suggestions (a word corrected by hand several times) do not exist yet.
            HStack(spacing: 6) {
                Text("Suggested")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                SoonBadge()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .overlay(Capsule().stroke(STheme.border, lineWidth: 1))
            .fixedSize()
            .opacity(0.7)
            .help("Words you correct by hand will be suggested here")
        }
    }

    private func chip(_ value: DictionaryFilter, title: LocalizedStringKey, count: Int) -> some View {
        SFilterChip(label: Text(title) + Text(verbatim: " · \(count)"),
                    selected: filter == value) { filter = value }
    }

    private var emptyMessage: LocalizedStringKey {
        switch filter {
        case .all: return "Nothing here yet. Add a name you say often, or a word the model keeps getting wrong."
        case .words: return "No new words yet."
        case .corrections: return "No corrections yet."
        }
    }

    private func save(_ entry: CustomDictionaryEntry) {
        if let index = viewModel.customDictionaryEntries.firstIndex(where: { $0.id == entry.id }) {
            viewModel.customDictionaryEntries[index] = entry
        } else {
            viewModel.customDictionaryEntries.append(entry)
        }
        editing = nil
    }

    private func delete(_ entry: CustomDictionaryEntry) {
        viewModel.customDictionaryEntries.removeAll { $0.id == entry.id }
    }

    private func openSnapshotEditorIfAsked() {
        #if DEBUG
        if Self.snapshotOpensFirstEntry {
            editing = entries.first { $0.kind == .correction } ?? entries.first
        }
        #endif
    }
}

/// The global switches that shape every entry, above the list.
private struct DictionaryOptionsGroup: View {
    @ObservedObject var viewModel: SettingsViewModel
    let hasWords: Bool
    let onTeachPunctuation: () -> Void

    var body: some View {
        SettingsGroup("Options", accessory: {
            // Punctuation is the case nobody gets right by hand: the phrasing is personal and
            // the spacing is fiddly. Reading a few sentences settles both.
            Button(action: onTeachPunctuation) {
                Label("Teach punctuation", systemImage: "text.quote")
            }
            .buttonStyle(.sSecondary)
            .disabled(!viewModel.customDictionaryEnabled)
        }) {
            SettingRow("Use the dictionary",
                       hint: "Whole-word replacement, case-insensitive. Write \\n in a replacement for a line break.") {
                SSwitch(isOn: $viewModel.customDictionaryEnabled)
            }
            SettingRow("Help recognition of these words",
                       hint: "Also bias the model toward these terms while listening, not just fix them afterwards. Helps rare, distinctive words, but can over-correct short, common ones. Applies to every entry.",
                       indented: true) {
                SSwitch(isOn: $viewModel.customDictionaryBoostEnabled)
                    .disabled(!viewModel.customDictionaryEnabled)
            }
            if !viewModel.customDictionaryEnabled {
                SettingNotice("The dictionary is off. Your entries are kept but nothing is replaced or recognised better.")
            } else if hasWords && !viewModel.customDictionaryBoostEnabled {
                SettingNotice("New words only help recognition when “Help recognition of these words” is on.")
            }
        }
    }
}
