import SwiftUI
import OpenSuperWhisperCore

/// Snippets: a short phrase said, a longer text written in its place (#167). Built as the
/// Dictionary page's sibling: the switches on top, one row per snippet, and a modal editor
/// working on a copy that lands in `viewModel.snippets` only on Save.
struct SnippetsPage: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// The snippet open in the editor: an existing one, or a fresh one not yet in the list.
    @State private var editing: Snippet?

    #if DEBUG
    /// Lets the snapshot renderer show the editor open on the first snippet.
    static var snapshotOpensFirstSnippet = false
    /// Lets it show the editor on a new snippet started from this phrase, still without text.
    static var snapshotStartsSnippet: String?
    #endif

    private var snippets: [Snippet] { viewModel.snippets }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Snippets",
                           subtitle: "Say a short phrase, get a longer text. Your email, a link, a signature, written exactly as you typed it.") {
                    Button {
                        editing = Snippet()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.sPrimary)
                }
                SnippetsOptionsGroup(viewModel: viewModel)
                if snippets.isEmpty {
                    SnippetsEmptyState { editing = Snippet(trigger: $0) }
                } else {
                    SnippetList(snippets: snippets,
                                dimmed: !viewModel.snippetsEnabled,
                                onEdit: { editing = $0 },
                                onDelete: delete)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if let snippet = editing {
                ModalCard(maxWidth: 600, maxHeight: 900, onClose: { editing = nil }) {
                    SnippetEditor(
                        initial: snippet,
                        isNew: !snippets.contains { $0.id == snippet.id },
                        otherTriggerKeys: snippets.filter { $0.id != snippet.id }.map(\.triggerKey),
                        dictionary: viewModel.customDictionaryEnabled ? viewModel.customDictionaryEntries : [],
                        onSave: save,
                        onDelete: { delete(snippet); editing = nil },
                        onClose: { editing = nil })
                }
                .id(snippet.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: editing?.id)
        .onAppear(perform: openSnapshotEditorIfAsked)
    }

    private func save(_ snippet: Snippet) {
        if let index = viewModel.snippets.firstIndex(where: { $0.id == snippet.id }) {
            viewModel.snippets[index] = snippet
        } else {
            viewModel.snippets.append(snippet)
        }
        editing = nil
    }

    private func delete(_ snippet: Snippet) {
        viewModel.snippets.removeAll { $0.id == snippet.id }
    }

    private func openSnapshotEditorIfAsked() {
        #if DEBUG
        if Self.snapshotOpensFirstSnippet {
            editing = snippets.first { $0.trimmedExpansion.contains("\n") } ?? snippets.first
        } else if let trigger = Self.snapshotStartsSnippet {
            editing = Snippet(trigger: trigger)
        }
        #endif
    }
}

/// The two switches that apply to every snippet, above the list.
private struct SnippetsOptionsGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Options") {
            SettingRow("Use snippets",
                       hint: "Whole words, any case, said alone or mid-sentence. Expanded after AI formatting, so your text is never rewritten.") {
                SSwitch(isOn: $viewModel.snippetsEnabled)
            }
            if viewModel.snippetsEnabled {
                SettingRow("Help recognition of triggers",
                           hint: "Also bias the model toward your triggers while listening. Helps unusual phrases, but can over-correct short, common ones.",
                           indented: true) {
                    SSwitch(isOn: $viewModel.snippetsBoostEnabled)
                }
            }
        }
    }
}

/// What the page shows before the first snippet: what one is for, and three to start from.
private struct SnippetsEmptyState: View {
    let onStart: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No snippets yet. Pick a phrase you would rather say than type.")
                .scaledFont(size: 14)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                example(String(localized: "my email"), symbol: "at")
                example(String(localized: "my calendar link"), symbol: "link")
                example(String(localized: "sign off"), symbol: "signature")
            }
        }
        .padding(.vertical, 28)
    }

    private func example(_ trigger: String, symbol: String) -> some View {
        Button { onStart(trigger) } label: {
            Label {
                Text(verbatim: trigger)
            } icon: {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.sSecondary)
        .help(Text("Start a snippet with this phrase"))
    }
}
