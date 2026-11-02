import AppKit
import XCTest

@testable import OpenSuperWhisper

/// The Settings window is one native window that opens, focuses, closes and opens again (#252).
@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    private var controller: SettingsWindowController!

    override func setUp() async throws {
        // No frame autosave: a test window must not write into the real preferences.
        controller = SettingsWindowController(autosaveName: nil, viewModel: SettingsViewModel())
    }

    override func tearDown() async throws {
        controller.close()
        AppNavigation.shared.settingsFocusRow = nil
    }

    func testTheWindowIsTitledSettingsAndResizableDownToTheMinimumOnly() throws {
        controller.show()

        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, NSLocalizedString("Settings", comment: ""))
        XCTAssertTrue(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertEqual(window.contentMinSize, SettingsWindowController.minimumSize)
        XCTAssertEqual(window.contentLayoutRect.size.width, SettingsWindowController.defaultSize.width, accuracy: 1)
        XCTAssertTrue(window.isVisible)
    }

    func testShowingItAgainReusesTheOpenWindow() throws {
        controller.show()
        let first = try XCTUnwrap(controller.window)

        controller.show()

        XCTAssertTrue(controller.window === first, "a second Settings window opened")
    }

    func testTheDockIconComesWithTheWindow() {
        controller.show()

        XCTAssertEqual(NSApplication.shared.activationPolicy(), .regular)
    }

    func testClosingItReleasesTheWindowAndItsPendingScrollTarget() async throws {
        controller.show()
        AppNavigation.shared.settingsFocusRow = "Microphone"
        let window = try XCTUnwrap(controller.window)

        controller.close()

        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(AppNavigation.shared.settingsFocusRow)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(window.contentView, "the panes stayed alive in the closed window")
    }

    func testItOpensAgainAfterBeingClosed() throws {
        controller.show()
        controller.close()

        controller.show()

        XCTAssertTrue(controller.isOpen)
        XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)
    }
}
