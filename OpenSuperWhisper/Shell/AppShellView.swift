import SwiftUI
import OpenSuperWhisperCore

/// The main window once onboarding is done: the sidebar with the everyday pages, the page
/// itself, and Help and Feedback opening over it as cards. The settings have their own window.
struct AppShellView: View {
    /// Shared with the Settings window: the pages here show what it edits.
    @ObservedObject private var viewModel: SettingsViewModel
    @StateObject private var permissions = PermissionsManager()
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var fileDrop = FileDropHandler.shared
    @StateObject private var feedback: FeedbackFormModel
    /// Handed to the report cards, which observe it themselves: the shell has no need to redraw
    /// when a report is saved.
    private let reports = TranscriptionReportsModel.shared
    @State private var previousModelURL: URL?

    /// The window as `AppNavigation` has it. The scene builds this again on every redraw, one per
    /// step of the Text size slider among others, so it must leave the navigation alone: writing
    /// the page here put it back under the slider (#207).
    init(feedback: @autoclosure @escaping () -> FeedbackFormModel = FeedbackFormModel()) {
        viewModel = .shared
        _feedback = StateObject(wrappedValue: feedback())
    }

    /// Opens the window on `page`, for the layout tests, which open each page in turn, and the
    /// snapshot probe, which also hands in a Feedback draft it staged. Only for a view built
    /// once: every rebuild puts this page back. It gets a view model of its own, read fresh
    /// from the preferences the test just set.
    init(page: AppPage, feedback: @autoclosure @escaping () -> FeedbackFormModel = FeedbackFormModel()) {
        AppNavigation.shared.page = page
        viewModel = SettingsViewModel()
        _feedback = StateObject(wrappedValue: feedback())
    }

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(viewModel: viewModel, permissions: permissions)
            Rectangle().fill(STheme.border).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                    .zIndex(1)
                pageStack
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            .background(STheme.windowBg.ignoresSafeArea())
        }
        // The title bar is hidden: the traffic lights sit over the sidebar and the top bar
        // starts at the window's edge, as in the design.
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if navigation.helpOpen {
                HelpOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if navigation.feedbackOpen {
                FeedbackOverlay(model: feedback, asked: navigation.feedbackAsked)
                    .transition(.opacity)
            } else if let recording = navigation.reporting {
                ReportCard(recording: recording, dictionaryEnabled: $viewModel.customDictionaryEnabled,
                           addToDictionary: { entry in
                               viewModel.customDictionaryEntries = ReportDraft.adding(
                                   entry, to: viewModel.customDictionaryEntries)
                           },
                           reports: reports)
                    .id(recording.id)
                    .transition(.opacity)
            } else if navigation.reportsOpen {
                ReportsCard(reports: reports)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: navigation.helpOpen)
        .animation(.easeOut(duration: 0.15), value: navigation.feedbackOpen)
        .animation(.easeOut(duration: 0.15), value: navigation.reporting?.id)
        .animation(.easeOut(duration: 0.15), value: navigation.reportsOpen)
        // Whatever closed the card (✕, Esc, the sidebar, ⌘,), its thank-you is not shown again.
        .onChange(of: navigation.feedbackOpen) { _, open in
            if !open { feedback.cardClosed() }
        }
        .asksForFeedbackOnce()
        .environmentObject(permissions)
        .tint(STheme.accent)
        .frame(minWidth: 840, idealWidth: 1080, minHeight: 640, idealHeight: 760)
        .fileDropHandler()
        .onChange(of: fileDrop.isDragging) { _, dragging in
            if dragging {
                navigation.page = .home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTranscriptions)) { _ in
            navigation.closeReports()
            navigation.helpOpen = false
            navigation.feedbackOpen = false
            navigation.page = .home
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        // Injected from the view model rather than read from preferences at window
        // construction: preferences aren't observed, so the slider wrote a value nothing
        // ever re-read and the setting appeared to do nothing until the app restarted.
        .environment(\.appTextScale, viewModel.textScale)
    }

    /// Home stays mounted under the other pages. Rebuilt on every visit, it lost the search, the
    /// scroll position and the expanded cards, and a recording started from its button kept
    /// running with nobody left to cancel it on Esc.
    private var pageStack: some View {
        let showingHome = navigation.page == .home
        return ZStack(alignment: .topLeading) {
            HomePage()
                .opacity(showingHome ? 1 : 0)
                .allowsHitTesting(showingHome)
                .accessibilityHidden(!showingHome)
            switch navigation.page {
            case .home:
                EmptyView()
            case .dictionary:
                DictionaryPage(viewModel: viewModel)
                    .background(STheme.windowBg)
            case .snippets:
                SnippetsPage(viewModel: viewModel)
                    .background(STheme.windowBg)
            case .style:
                StylePage(viewModel: viewModel)
                    .background(STheme.windowBg)
            }
        }
    }
}

/// The strip above every page: where you are, and the search field.
struct TopBar: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(navigation.page.title)
                .scaledFont(size: 13)
                .foregroundColor(STheme.textSecondary)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                TextField("Search dictations, words, settings", text: $navigation.searchText)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textBright)
                    .focused($searchFocused)
                    .onChange(of: navigation.searchText) { _, text in
                        if !text.isEmpty { navigation.page = .home }
                    }
                if navigation.searchText.isEmpty {
                    ShortcutBadge(text: "⌘K")
                } else {
                    Button {
                        navigation.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 12)
                            .foregroundColor(STheme.hint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if searchFocused {
                    SearchSuggestions(query: navigation.searchText) { searchFocused = false }
                        .offset(y: 40)
                }
            }
            .background(
                Group {
                    Button("") { searchFocused = true }
                        .keyboardShortcut("k", modifiers: .command)
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                }
                .opacity(0)
                .accessibilityHidden(true)
            )
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .focusTranscriptionSearch)) { _ in
            searchFocused = true
        }
    }
}

/// Under the window's search field: the settings, dictionary words and snippets that match,
/// while the Home feed below filters the dictations themselves.
private struct SearchSuggestions: View {
    let query: String
    let dismiss: () -> Void
    @ObservedObject private var navigation = AppNavigation.shared

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var settings: [SettingsSearchEntry] {
        Array(SettingsSearchIndex.entries.filter { $0.matches(trimmed) }.prefix(5))
    }

    private var words: [CustomDictionaryEntry] {
        Array(AppPreferences.shared.customDictionaryEntries.filter { entry in
            entry.replacement.localizedCaseInsensitiveContains(trimmed)
                || entry.triggers.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }.prefix(3))
    }

    private var snippets: [Snippet] {
        Array(AppPreferences.shared.snippets.filter { snippet in
            snippet.trigger.localizedCaseInsensitiveContains(trimmed)
                || snippet.expansion.localizedCaseInsensitiveContains(trimmed)
        }.prefix(3))
    }

    var body: some View {
        if trimmed.count >= 2, !(settings.isEmpty && words.isEmpty && snippets.isEmpty) {
            VStack(alignment: .leading, spacing: 2) {
                if !settings.isEmpty {
                    sectionTitle("Settings")
                    ForEach(settings) { entry in
                        suggestion(title: Text(LocalizedStringKey(entry.title)), detail: Text(entry.rubric.title)) {
                            if entry.advanced { AdvancedRubrics.shared.set(entry.rubric.rawValue, true) }
                            navigation.searchText = ""
                            navigation.openSettings(entry.rubric, focusing: entry.title)
                        }
                    }
                }
                if !words.isEmpty {
                    sectionTitle("Dictionary")
                    ForEach(words) { entry in
                        suggestion(title: Text(verbatim: entry.replacement),
                                   detail: Text(verbatim: entry.triggers.joined(separator: ", "))) {
                            navigation.searchText = ""
                            navigation.go(.dictionary)
                        }
                    }
                }
                if !snippets.isEmpty {
                    sectionTitle("Snippets")
                    ForEach(snippets) { snippet in
                        suggestion(title: Text(verbatim: snippet.trimmedTrigger),
                                   detail: Text(verbatim: firstLine(of: snippet.trimmedExpansion))) {
                            navigation.searchText = ""
                            navigation.go(.snippets)
                        }
                    }
                }
            }
            .padding(6)
            .frame(width: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
    }

    private func firstLine(of text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .scaledFont(size: 11, weight: .bold)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundColor(STheme.hint)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func suggestion(title: Text, detail: Text, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                title
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .lineLimit(1)
                detail
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
