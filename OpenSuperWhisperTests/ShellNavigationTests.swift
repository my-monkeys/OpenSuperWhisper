import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The windows keep their page, rubric and scroll position when the scene redraws (#207), and
/// the settings are routed to their own window (#252).
///
/// The scene's body runs again on every step of the Text size slider, since it reads the scale
/// through @AppStorage, and each run builds a new `AppShellView` value. Building one used to write
/// the page into `AppNavigation`, so the settings card closed under the slider at its first step.
@MainActor
final class ShellNavigationTests: XCTestCase {

    private var preferences: ScratchPreferences!
    private var appearanceAdvanced = false
    private let navigation = AppNavigation.shared
    private var settingsWindowShown = 0
    private var dashboardShown = 0

    override func setUp() async throws {
        appearanceAdvanced = AdvancedRubrics.shared.isOn(SettingsRubric.appearance.rawValue)
        preferences = ScratchPreferences()
        settingsWindowShown = 0
        dashboardShown = 0
        navigation.presentSettingsWindow = { [unowned self] in settingsWindowShown += 1 }
        navigation.presentDashboardWindow = { [unowned self] in dashboardShown += 1 }
        reset()
    }

    override func tearDown() async throws {
        reset()
        AdvancedRubrics.shared.set(SettingsRubric.appearance.rawValue, appearanceAdvanced)
        preferences.restore()
    }

    func testOpeningTheSettingsShowsTheWindowOnTheRubricAndRow() {
        navigation.openSettings(.privacy, focusing: "Suggest words from your corrections")

        XCTAssertEqual(settingsWindowShown, 1)
        XCTAssertEqual(navigation.settingsRubric, .privacy)
        XCTAssertEqual(navigation.settingsFocusRow, "Suggest words from your corrections")
        XCTAssertEqual(dashboardShown, 0, "the settings do not need the dashboard")
    }

    func testShowingTheSettingsAgainKeepsTheRubricTheyWereLeftOn() {
        navigation.openSettings(.models, focusing: "Server")

        navigation.showSettings()

        XCTAssertEqual(settingsWindowShown, 2)
        XCTAssertEqual(navigation.settingsRubric, .models)
        XCTAssertNil(navigation.settingsFocusRow, "a stale row would scroll the pane again")
    }

    func testLeavingTheSettingsForAPageBringsTheDashboardAndClearsItsCards() {
        navigation.helpOpen = true
        navigation.feedbackOpen = true

        navigation.showDashboard(.style)

        XCTAssertEqual(navigation.page, .style)
        XCTAssertFalse(navigation.helpOpen)
        XCTAssertFalse(navigation.feedbackOpen)
        XCTAssertEqual(dashboardShown, 1)
    }

    func testReleaseNotesOpenHelpOnTheDashboard() {
        navigation.feedbackOpen = true

        navigation.openHelp()

        XCTAssertTrue(navigation.helpOpen)
        XCTAssertFalse(navigation.feedbackOpen)
        XCTAssertEqual(dashboardShown, 1)
    }

    func testBuildingTheShellLeavesTheNavigationAlone() {
        navigation.go(.dictionary)
        navigation.openSettings(.appearance)

        _ = AppShellView()

        XCTAssertEqual(navigation.page, .dictionary)
        XCTAssertEqual(navigation.settingsRubric, .appearance)
    }

    func testTheSettingsKeepTheirRubricAndScrollWhileTheTextSizeChanges() async throws {
        // Advanced on and the smallest window, so the rubric is long enough to scroll.
        AdvancedRubrics.shared.set(SettingsRubric.appearance.rawValue, true)
        let viewModel = SettingsViewModel()
        navigation.settingsRubric = .appearance
        let host = NSHostingView(rootView: SettingsWindowView(viewModel: viewModel))
        let size = SettingsWindowController.minimumSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.close() }
        try await settle(host)

        let scroll = tallestScrollView(in: host)
        XCTAssertNotNil(scroll, "no scrollable view with the Appearance rubric open")
        scroll?.contentView.scroll(to: NSPoint(x: 0, y: 60))
        scroll.map { $0.reflectScrolledClipView($0.contentView) }
        try await settle(host)
        let offset = scroll?.contentView.bounds.origin.y ?? 0
        XCTAssertGreaterThan(offset, 0, "the rubric did not scroll")

        // What the slider writes on each step of a drag.
        for scale in stride(from: TextScale.default + 0.05, through: TextScale.default + 0.3, by: 0.05) {
            viewModel.textScale = scale
            try await settle(host)
            XCTAssertEqual(navigation.settingsRubric, .appearance, "the rubric changed at \(scale)")
        }

        if let scroll {
            XCTAssertTrue(scroll.isDescendant(of: host), "the rubric was rebuilt, losing its scroll position")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 1,
                           "the rubric scrolled away")
        }
    }

    // MARK: - Helpers

    private func reset() {
        navigation.settingsRubric = .dictation
        navigation.settingsFocusRow = nil
        navigation.helpOpen = false
        navigation.feedbackOpen = false
        navigation.closeReports()
        navigation.searchText = ""
        navigation.go(.home)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
    }

    /// The open rubric's: the longest scrollable content in the window while the card is open.
    private func tallestScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 60 {
                found.append(scroll)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
