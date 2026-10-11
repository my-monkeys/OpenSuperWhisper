import SwiftUI
import OpenSuperWhisperCore

/// One searchable setting: the row's title (its catalog key, which is also its scroll id), the
/// rubric it lives in, whether it only shows with Advanced on, and extra words people search
/// with ("mic" for Microphone).
struct SettingsSearchEntry: Identifiable {
    let title: String
    let rubric: SettingsRubric
    var advanced = false
    var keywords = ""
    var id: String { "\(rubric.rawValue).\(title)" }

    func matches(_ query: String) -> Bool {
        let localized = String(localized: String.LocalizationValue(title))
        return localized.localizedCaseInsensitiveContains(query)
            || title.localizedCaseInsensitiveContains(query)
            || keywords.localizedCaseInsensitiveContains(query)
    }
}

/// The settings, as a card over the main window (⌘, opens it, ✕ or Esc closes it): the rubric
/// list with its search on the left, the rubric on the right.
struct SettingsOverlay: View {
    @ObservedObject var viewModel: SettingsViewModel
    let rubric: SettingsRubric
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var search = ""
    @Environment(\.textScaleFactor) private var textScale
    @FocusState private var searchFocused: Bool

    var body: some View {
        ModalCard(onClose: navigation.closeSettings) {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(STheme.border).frame(width: 1)
                rubricView
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
    }

    // MARK: Sidebar

    private var results: [SettingsSearchEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return SettingsSearchIndex.entries.filter { $0.matches(query) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS")
                .scaledFont(size: 12, weight: .bold)
                .tracking(1.2)
                .foregroundColor(STheme.hint)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            searchField
                .padding(.bottom, 10)
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsRubric.allCases) { item in
                    rubricRow(item)
                }
            } else {
                searchResults
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(verbatim: "v\(UpdateChecker.currentVersion) ·")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                Button("Release notes") {
                    navigation.closeSettings()
                    navigation.helpOpen = true
                }
                .buttonStyle(.plain)
                .scaledFont(size: 12)
                .foregroundColor(STheme.accent)
            }
            .padding(.horizontal, 12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: 220 * min(max(textScale, 1), 1.45))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(STheme.sidebarBg)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 11)
                .foregroundColor(STheme.hint)
            TextField("Search…", text: $search)
                .textFieldStyle(.plain)
                .scaledFont(size: 13)
                .foregroundColor(STheme.textBright)
                .focused($searchFocused)
            if search.isEmpty { ShortcutBadge(text: "⌘K") }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private func rubricRow(_ item: SettingsRubric) -> some View {
        let selected = item == rubric
        return Button {
            navigation.openSettings(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .scaledFont(size: 13, weight: .medium)
                    .frame(width: 18)
                    .foregroundColor(selected ? STheme.accent : STheme.hint)
                Text(item.title)
                    .scaledFont(size: 15, weight: selected ? .bold : .medium)
                    .foregroundColor(selected ? STheme.accent : STheme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? STheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            Text("No setting matches.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .padding(.horizontal, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { entry in
                        Button {
                            if entry.advanced { AdvancedRubrics.shared.set(entry.rubric.rawValue, true) }
                            navigation.openSettings(entry.rubric, focusing: entry.title)
                            search = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(entry.title))
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundColor(STheme.textBright)
                                Text(entry.rubric.title)
                                    .scaledFont(size: 12)
                                    .foregroundColor(STheme.hint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Rubric

    @ViewBuilder private var rubricView: some View {
        switch rubric {
        case .general: GeneralRubric(viewModel: viewModel)
        case .dictation: DictationRubric(viewModel: viewModel)
        case .models: ModelsRubric(viewModel: viewModel)
        case .textAndAI: TextAndAIRubric(viewModel: viewModel)
        case .appearance: AppearanceRubric(viewModel: viewModel)
        case .assistants: AssistantsRubric()
        case .privacy: PrivacyRubric(viewModel: viewModel)
        case .advanced: AdvancedRubric(viewModel: viewModel)
        }
    }
}

/// Every setting the search can find, gathered from the rubrics that declare them.
enum SettingsSearchIndex {
    static var entries: [SettingsSearchEntry] {
        GeneralRubric.searchEntries
            + DictationRubric.searchEntries
            + ModelsRubric.searchEntries
            + TextAndAIRubric.searchEntries
            + AppearanceRubric.searchEntries
            + AssistantsRubric.searchEntries
            + PrivacyRubric.searchEntries
            + AdvancedRubric.searchEntries
    }
}

/// A rubric's page: title, one line of intro, the Advanced switch and the close button, then the
/// groups. Scrolls to `AppNavigation.settingsFocusRow` when the search picked a row here.
struct RubricPage<Content: View>: View {
    let rubric: SettingsRubric
    let intro: LocalizedStringKey
    /// Rubrics with nothing advanced in them hide the switch.
    var hasAdvanced = true
    @ViewBuilder var content: () -> Content
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var advanced = AdvancedRubrics.shared

    init(_ rubric: SettingsRubric, intro: LocalizedStringKey, hasAdvanced: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.rubric = rubric
        self.intro = intro
        self.hasAdvanced = hasAdvanced
        self.content = content
    }

    private var showsAdvanced: Bool { !hasAdvanced || advanced.isOn(rubric.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
            ScrollViewReader { proxy in
                ScrollView {
                    SPaneStack(spacing: 26) { content() }
                        .padding(.horizontal, 32).padding(.bottom, 32)
                }
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: navigation.settingsFocusRow) { _, _ in scrollToFocus(proxy) }
            }
        }
        .environment(\.showsAdvanced, showsAdvanced)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rubric.title)
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text(intro)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if hasAdvanced {
                HStack(spacing: 8) {
                    Text("Advanced")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    SSwitch(isOn: Binding(
                        get: { advanced.isOn(rubric.rawValue) },
                        set: { advanced.set(rubric.rawValue, $0) }))
                    .controlSize(.small)
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
                .background(Capsule().fill(STheme.controlBg))
                .overlay(Capsule().stroke(STheme.border, lineWidth: 1))
                .fixedSize()
            }
            CloseButton(action: navigation.closeSettings)
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let row = navigation.settingsFocusRow else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
        }
    }
}
