import SwiftUI
import OpenSuperWhisperCore

/// The main window once onboarding is done: the sidebar with the everyday pages, the page
/// itself, and the settings and Help opening over it as cards.
struct AppShellView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var permissions = PermissionsManager()
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var fileDrop = FileDropHandler.shared
    @State private var previousModelURL: URL?

    /// For the layout tests, which open the settings on each rubric in turn.
    init(page: AppPage = .home, settings rubric: SettingsRubric? = nil) {
        AppNavigation.shared.page = page
        AppNavigation.shared.settingsRubric = rubric
    }

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(viewModel: viewModel, permissions: permissions)
            Rectangle().fill(STheme.border).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
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
            if let rubric = navigation.settingsRubric {
                SettingsOverlay(viewModel: viewModel, rubric: rubric)
                    .transition(.opacity)
            } else if navigation.helpOpen {
                HelpOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: navigation.settingsRubric)
        .animation(.easeOut(duration: 0.15), value: navigation.helpOpen)
        .environmentObject(permissions)
        .tint(STheme.accent)
        .frame(minWidth: 840, idealWidth: 1080, minHeight: 640, idealHeight: 760)
        .fileDropHandler()
        .onChange(of: fileDrop.isDragging) { _, dragging in
            if dragging {
                navigation.closeSettings()
                navigation.page = .home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsPane)) { _ in
            if navigation.settingsRubric == nil { navigation.openSettings(.dictation) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTranscriptions)) { _ in
            navigation.closeSettings()
            navigation.helpOpen = false
            navigation.page = .home
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
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
            case .home, .snippets:
                EmptyView()
            case .dictionary:
                DictionaryPage(viewModel: viewModel)
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
                TextField("Search dictations", text: $navigation.searchText)
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
