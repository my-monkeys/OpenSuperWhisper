import SwiftUI
import OpenSuperWhisperCore

/// What opens under "›": the style, AI cleanup, insertion and model menus, the typing pace for a
/// typed app, its formatting instructions, and the actions on the row.
struct PerAppDetail: View {
    let entry: PerAppEntry
    @ObservedObject var viewModel: SettingsViewModel
    let models: [DictationModelOption]
    let showsModelMenu: Bool
    let isOn: Bool
    let onRemove: () -> Void
    let onChangeApp: () -> Void
    let onAddSite: (String) -> Void

    @State private var addingSite = false
    @State private var siteDraft = ""

    private var store: PerAppStore { PerAppStore(viewModel: viewModel) }
    private var pickers: PerAppPickers { PerAppPickers(entry: entry, viewModel: viewModel, models: models) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !isOn {
                note("Switched off: none of the settings below apply. They are kept for when you switch it back on.")
            }
            if entry.isSite {
                note("A site rule picks the transcription model, the writing style and AI cleanup, in Safari, Arc and other supported browsers. Insertion and formatting follow the app.")
                styleSection
                cleanupSection
                modelSection
            } else {
                styleSection
                cleanupSection
                insertionSection
                modelSection
                formattingSection
            }
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.advancedBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }

    // MARK: - Style and model

    private var styleSection: some View {
        section("Style") {
            pickers.styleMenu
            note(entry.isSite
                 ? "The voice AI cleanup writes in on this site. Default follows the app's style, then the one chosen on the Style page."
                 : "The voice AI cleanup writes in for this app. Default follows the style chosen on the Style page.")
        }
    }

    private var cleanupSection: some View {
        section("AI cleanup") {
            pickers.cleanupMenu
            note(entry.isSite
                 ? "The switch is in Text & AI. This overrides it for this site."
                 : "The switch is in Text & AI. This overrides it for this app.")
        }
    }

    @ViewBuilder private var modelSection: some View {
        if showsModelMenu {
            section("Model") {
                pickers.modelMenu
                note("Switches to this model when the app comes to the front. Default keeps the model in effect.")
            }
        } else if let model = entry.model {
            section("Model") {
                note("\(model.displayName). Model rules need at least two models to switch between.")
            }
        }
    }

    // MARK: - Insertion

    @ViewBuilder private var insertionSection: some View {
        section("Insertion") {
            // A remote session is typed key by key whatever a rule says, so the Paste/Type menu
            // and its notes would describe a choice that has no effect there.
            if isRemoteSessionApp {
                keyboard(note: "This app is always typed key by key, because the text goes to another computer. Choose the layout that computer uses.")
                if entry.insertion != nil { typingPace }
            } else {
                pickers.insertionMenu
                switch entry.insertion?.mode {
                case nil:
                    note("Follows the global “Paste instead of typing” switch. Choose Paste or Type to override it for this app.")
                case .paste?:
                    note("One ⌘V. Immune to apps that redraw on every keystroke, but uses the clipboard.")
                case .type?:
                    note("Synthetic keystrokes. Leaves the clipboard alone. Raise the pace if this app falls behind.")
                    typingPace
                    keyboard(note: "The layout of the computer the text is typed into, for remote sessions and virtual machines. Leave on “Same as this Mac” otherwise.")
                }
            }
        }
    }

    private var isRemoteSessionApp: Bool { RemoteSession.isRemoteSession(entry.bundleID) }

    private func keyboard(note text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Keyboard")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundColor(STheme.textBright)
                pickers.keyboardMenu
            }
            note(text)
        }
    }

    // Only typing has a pace to set, and only here is it worth setting: the global dial slows
    // every app, and the apps that need it are the exception.
    private var typingPace: some View {
        let pace = entry.insertion?.typingPaceMilliseconds
        return HStack(spacing: 12) {
            SSwitch(isOn: Binding(
                get: { pace != nil },
                set: { store.setTypingPace($0 ? viewModel.typingPaceMilliseconds : nil, for: entry) }))
            Text("Custom typing pace")
                .scaledFont(size: 14, weight: .medium)
                .foregroundColor(STheme.textBright)
            if let pace {
                Stepper(value: Binding(get: { pace }, set: { store.setTypingPace($0, for: entry) }),
                        in: 0...TextInserter.maxChunkPauseMilliseconds) {
                    Text(verbatim: "\(pace) ms")
                        .scaledFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundColor(STheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Formatting

    private var formattingSection: some View {
        section("Formatting instructions") {
            if !viewModel.appContextFormattingEnabled {
                note("“Reformat per app” is off, so these instructions are not used.")
            }
            ForEach(entry.profiles) { profile in
                VStack(alignment: .trailing, spacing: 6) {
                    SEditor(text: instructions(for: profile.id), height: 96)
                    Button("Remove instructions") { store.removeProfile(profile.id) }
                        .buttonStyle(.sQuiet)
                }
            }
            if entry.profiles.isEmpty {
                Button {
                    store.addProfile(for: entry)
                } label: {
                    Label("Add formatting instructions", systemImage: "plus")
                }
                .buttonStyle(.sSecondary)
                .disabled(!entry.hasBundle)
            }
        }
    }

    /// Resolved by id on every access, so an edit never writes into a profile that was removed.
    private func instructions(for id: UUID) -> Binding<String> {
        Binding(
            get: { viewModel.appContextProfiles.first { $0.id == id }?.instructions ?? "" },
            set: { text in
                guard let index = viewModel.appContextProfiles.firstIndex(where: { $0.id == id }) else { return }
                viewModel.appContextProfiles[index].instructions = text
            })
    }

    // MARK: - Pieces

    private var actions: some View {
        HStack(spacing: 10) {
            if !entry.isSite {
                Button("Change app…", action: onChangeApp)
                    .buttonStyle(.sSecondary)
            }
            if SourceCapture.isSupportedBrowser(bundleID: entry.bundleID), !entry.isSite {
                Button("Add a site…") { siteDraft = ""; addingSite = true }
                    .buttonStyle(.sSecondary)
                    .alert("Add a site", isPresented: $addingSite) {
                        TextField("Site address", text: $siteDraft, prompt: Text(verbatim: "mail.google.com"))
                        Button("Add") {
                            if let host = SourceCapture.normalizedHost(siteDraft) { onAddSite(host) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The site's address, for example mail.google.com.")
                    }
            }
            Spacer(minLength: 0)
            Button(entry.isSite ? "Remove site" : "Remove app", action: onRemove)
                .buttonStyle(.sDanger)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.textBright)
            content()
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .scaledFont(size: 13)
            .foregroundColor(STheme.hint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
