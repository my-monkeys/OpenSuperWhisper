import ApplicationServices
import SwiftUI
import OpenSuperWhisperCore

/// The custom dictionary: words the model should know and corrections to what it writes, one row
/// per written form. Edits go through a modal editor working on a copy, and land in
/// `viewModel.customDictionaryEntries` only on Save.
struct DictionaryPage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var suggestions = DictionarySuggestions.shared

    @State private var filter: DictionaryFilter = .all
    /// The entry open in the editor: an existing one, or a fresh one not yet in the list.
    @State private var editing: CustomDictionaryEntry?
    @State private var showPunctuationCalibration = false

    #if DEBUG
    /// Lets the snapshot renderer show the editor open on the first entry.
    static var snapshotOpensFirstEntry = false
    /// Lets the snapshot renderer show one filter, the Suggested list among them.
    static var snapshotFilter: DictionaryFilter?
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
                if filter == .suggested {
                    DictionarySuggestionList(suggestions: suggestions,
                                             emptyMessage: suggestionsEmptyMessage)
                } else {
                    DictionaryEntryList(entries: entries.filter(filter.includes),
                                        dimmed: !viewModel.customDictionaryEnabled,
                                        emptyMessage: emptyMessage,
                                        onEdit: { editing = $0 },
                                        onDelete: delete)
                }
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
            chip(.suggested, title: "Suggested", count: suggestions.pending.count)
                .help("Words you corrected by hand after a dictation, waiting for your answer")
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
        case .suggested: return suggestionsEmptyMessage
        }
    }

    private var suggestionsEmptyMessage: LocalizedStringKey {
        viewModel.suggestDictionaryWords && viewModel.customDictionaryEnabled
            ? "No suggestions yet. Fix a word in the text after a dictation, and it will be offered here."
            : "Turn on “Suggest words from your corrections” above, and the words you fix by hand after a dictation will be offered here."
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
        suggestions.noteDeleted(entry)
    }

    private func openSnapshotEditorIfAsked() {
        #if DEBUG
        if Self.snapshotOpensFirstEntry {
            editing = entries.first { $0.kind == .correction } ?? entries.first
        }
        if let snapshotFilter = Self.snapshotFilter {
            filter = snapshotFilter
        }
        #endif
    }
}

/// The global switches that shape every entry, above the list.
struct DictionaryOptionsGroup: View {
    @ObservedObject var viewModel: SettingsViewModel
    let hasWords: Bool
    let onTeachPunctuation: () -> Void
    /// Suggestions read the field through Accessibility, and do nothing without it, silently.
    @State private var canReadFields = Self.accessibilityAllowed()

    var body: some View {
        group
            .onAppear { canReadFields = Self.accessibilityAllowed() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                canReadFields = Self.accessibilityAllowed()
            }
    }

    #if DEBUG
    /// The snapshot probe draws the notice for a Mac without the permission.
    nonisolated(unsafe) static var snapshotDeniesAccessibility = false
    #endif

    static func accessibilityAllowed() -> Bool {
        #if DEBUG
        if snapshotDeniesAccessibility { return false }
        if PermissionsManager.snapshotGrantsAll { return true }
        #endif
        return AXIsProcessTrusted()
    }

    /// Asks macOS, which shows its own prompt with a way into System Settings; once refused, that
    /// prompt no longer appears, so the pane opens instead.
    private func askForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var group: some View {
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
                       hint: "On: the model is biased toward your words while listening, so it can recognise one it would otherwise mishear. Off: a New word only fixes the capitalisation of a word already spelt right. Helps rare, distinctive words, but can over-correct short, common ones: each entry can opt out in its editor.",
                       indented: true) {
                SSwitch(isOn: $viewModel.customDictionaryBoostEnabled)
                    .disabled(!viewModel.customDictionaryEnabled)
            }
            SettingRow("Suggest words from your corrections",
                       hint: "After a dictation, the field it went into is read again for up to a minute. A name or term you fix by hand is offered for the dictionary. It stays on your Mac, and the text read is never saved.",
                       indented: true) {
                SSwitch(isOn: $viewModel.suggestDictionaryWords)
                    .disabled(!viewModel.customDictionaryEnabled)
            }
            if viewModel.customDictionaryEnabled && viewModel.suggestDictionaryWords && !canReadFields {
                SettingNotice("Suggestions need Accessibility to read the field your dictation went into, and OpenSuperWhisper isn't allowed yet.") {
                    Button("Allow") { askForAccessibility() }
                        .buttonStyle(.sPrimary)
                }
            }
            if !viewModel.customDictionaryEnabled {
                SettingNotice("The dictionary is off. Your entries are kept but nothing is replaced or recognised better.")
            } else if hasWords && !viewModel.customDictionaryBoostEnabled {
                SettingNotice("“Help recognition of these words” is off, so a New word only fixes capitalisation, not a word the model mishears. Turn it on to have the model recognise it.")
            }
        }
    }
}
