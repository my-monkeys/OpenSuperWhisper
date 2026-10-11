import SwiftUI

/// The pages of the main window's sidebar.
enum AppPage: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "record.circle"
        case .dictionary: return "textformat"
        case .snippets: return "quote.opening"
        case .style: return "pencil.tip"
        }
    }

    /// Pages drawn in the sidebar but not built yet: shown with Soon, not clickable.
    var isAvailable: Bool { self != .snippets }
}

/// The rubrics of the settings, in sidebar order.
enum SettingsRubric: String, CaseIterable, Identifiable {
    case general, dictation, models, textAndAI, appearance, assistants, privacy, advanced
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .textAndAI: return "Text & AI"
        case .appearance: return "Appearance"
        case .assistants: return "Assistants"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    /// Catalog key of the title, for the settings search.
    var titleKey: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .textAndAI: return "Text & AI"
        case .appearance: return "Appearance"
        case .assistants: return "Assistants"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "macwindow"
        case .dictation: return "slider.horizontal.3"
        case .models: return "cpu"
        case .textAndAI: return "text.bubble"
        case .appearance: return "paintbrush.pointed"
        case .assistants: return "terminal"
        case .privacy: return "clock.arrow.circlepath"
        case .advanced: return "gearshape"
        }
    }
}

/// Where the main window is: which page, whether the settings or Help are open over it, and
/// which setting to bring into view. One shared instance so the menu bar, ⌘, and other windows
/// can route the main window without holding a reference to it.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var page: AppPage = .home
    /// The open settings rubric; nil when the settings are closed.
    @Published var settingsRubric: SettingsRubric?
    /// A row title to scroll to once its rubric is showing (set by the settings search).
    @Published var settingsFocusRow: String?
    @Published var helpOpen = false
    /// Text of the window's search field. Filters the Home feed.
    @Published var searchText = ""

    func openSettings(_ rubric: SettingsRubric = .dictation, focusing row: String? = nil) {
        helpOpen = false
        settingsRubric = rubric
        settingsFocusRow = row
    }

    func closeSettings() {
        settingsRubric = nil
        settingsFocusRow = nil
    }

    func go(_ page: AppPage) {
        guard page.isAvailable else { return }
        self.page = page
    }
}
