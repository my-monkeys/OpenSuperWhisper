import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The main window keeps its page, its open card and the card's scroll position when the scene
/// redraws (#207).
///
/// The scene's body runs again on every step of the Text size slider, since it reads the scale
/// through @AppStorage, and each run builds a new `AppShellView` value. Building one used to write
/// a page and a closed settings card into `AppNavigation`, so the settings closed under the slider
/// at its first step.
@MainActor
final class ShellNavigationTests: XCTestCase {

    private var preferences: ScratchPreferences!
    private var appearanceAdvanced = false
    private let navigation = AppNavigation.shared

    override func setUp() async throws {
        appearanceAdvanced = AdvancedRubrics.shared.isOn(SettingsRubric.appearance.rawValue)
        preferences = ScratchPreferences()
        reset()
    }

    override func tearDown() async throws {
        reset()
        AdvancedRubrics.shared.set(SettingsRubric.appearance.rawValue, appearanceAdvanced)
        preferences.restore()
    }

    func testBuildingTheShellLeavesTheNavigationAlone() {
        navigation.go(.dictionary)
        navigation.openSettings(.appearance)

        _ = AppShellView()

        XCTAssertEqual(navigation.page, .dictionary)
        XCTAssertEqual(navigation.settingsRubric, .appearance)
    }

    /// Per app was the lower half of Style (#257); the links that used to land on Style for it go
    /// to its own tab, which sits right after Style.
    func testPerAppIsItsOwnPageRightAfterStyle() {
        let pages = AppPage.allCases
        XCTAssertEqual(pages.firstIndex(of: .perApp), pages.firstIndex(of: .style).map { $0 + 1 })

        navigation.go(.perApp)
        XCTAssertEqual(navigation.page, .perApp)
    }

    func testTheSettingsStayOpenWhileTheTextSizeChanges() async throws {
        // Advanced on and the smallest window, so the rubric is long enough to scroll.
        AdvancedRubrics.shared.set(SettingsRubric.appearance.rawValue, true)
        let host = NSHostingView(rootView: SceneContent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 640)
        defer { window.close() }
        try await settle(host)

        navigation.go(.dictionary)
        navigation.openSettings(.appearance)
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
            AppPreferences.shared.textScale = scale
            try await settle(host)
            XCTAssertEqual(navigation.settingsRubric, .appearance, "the settings closed at \(scale)")
        }

        XCTAssertEqual(navigation.page, .dictionary)
        if let scroll {
            XCTAssertTrue(scroll.isDescendant(of: host), "the rubric was rebuilt, losing its scroll position")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 1,
                           "the rubric scrolled away")
        }
    }

    // MARK: - Helpers

    private func reset() {
        navigation.closeSettings()
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

/// The window's content as `OpenSuperWhisperApp` builds it once onboarding is done: the scale
/// read through @AppStorage above the shell, so a change redraws this body and builds a new
/// `AppShellView`.
private struct SceneContent: View {
    @AppStorage("textScale", store: DefaultsStore.current) private var textScale: Double = TextScale.default

    var body: some View {
        AppShellView()
            .environment(\.appTextScale, textScale)
    }
}
