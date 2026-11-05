import SwiftUI
import OpenSuperWhisperCore

/// The pages of the main window's sidebar.
enum AppPage: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, perApp
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .perApp: return "Per app"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "record.circle"
        case .dictionary: return "textformat"
        case .snippets: return "quote.opening"
        case .style: return "pencil.tip"
        case .perApp: return "app.dashed"
        }
    }
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

/// Where the app's windows are: which page the dashboard shows, whether Help or Feedback are
/// open over it, and which rubric and setting the Settings window shows. One shared instance so
/// the menu bar, ⌘, and the two windows can route each other without holding a reference.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var page: AppPage = .home
    /// The rubric the Settings window shows, kept when it is closed and opened again.
    @Published var settingsRubric: SettingsRubric = .dictation
    /// A row title to scroll to once its rubric is showing (set by the settings search).
    @Published var settingsFocusRow: String?
    @Published var helpOpen = false
    @Published var feedbackOpen = false {
        didSet { if !feedbackOpen { feedbackAsked = false } }
    }
    /// The open Feedback card was opened by the app asking, once (#206), rather than by the user:
    /// it leads with a note on the new interface. Cleared whenever the card closes.
    @Published private(set) var feedbackAsked = false
    /// The dictation the Report card is about (#168); nil when the card is closed.
    @Published var reporting: Recording?
    /// The saved reports, as a card over Home.
    @Published var reportsOpen = false
    /// Text of the window's search field. Filters the Home feed.
    @Published var searchText = ""

    /// How the two windows come forward. Swapped by the tests; a test host must not open real
    /// windows or reopen its own app bundle.
    var presentSettingsWindow: @MainActor () -> Void = {
        guard !DefaultsStore.isRunningTests else { return }
        SettingsWindowController.shared.show()
    }
    var presentDashboardWindow: @MainActor () -> Void = {
        guard !DefaultsStore.isRunningTests else { return }
        AppDelegate.shared?.showMainWindow()
    }

    func openSettings(_ rubric: SettingsRubric = .dictation, focusing row: String? = nil) {
        settingsRubric = rubric
        settingsFocusRow = row
        presentSettingsWindow()
    }

    /// ⌘, and the menu bar's "Settings…": the window as it was left.
    func showSettings() {
        openSettings(settingsRubric)
    }

    /// The dashboard on `page`, from a window that is not the dashboard. The cards go: they
    /// would hide the page it was asked to show.
    func showDashboard(_ page: AppPage) {
        helpOpen = false
        feedbackOpen = false
        closeReports()
        go(page)
        presentDashboardWindow()
    }

    func openHelp() {
        closeReports()
        feedbackOpen = false
        helpOpen = true
        presentDashboardWindow()
    }

    /// One card at a time: Feedback replaces Help when it opens.
    func openFeedback() {
        closeReports()
        helpOpen = false
        feedbackAsked = false
        feedbackOpen = true
    }

    func openReport(for recording: Recording) {
        helpOpen = false
        feedbackOpen = false
        reportsOpen = false
        reporting = recording
    }

    func openReports() {
        helpOpen = false
        feedbackOpen = false
        reporting = nil
        reportsOpen = true
    }

    func closeReports() {
        reporting = nil
        reportsOpen = false
    }

    /// The same card, opened by the app to ask for feedback. Only `FeedbackPromptScheduler`
    /// calls it, after recording that it asked.
    func askForFeedback() {
        openFeedback()
        feedbackAsked = true
    }

    func go(_ page: AppPage) {
        self.page = page
    }
}
