import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The ways out of the app (an issue on GitHub, a beta build) are offered twice, in Help & what's
/// new and under the Feedback card. They live in one place so the two cannot drift; these pin the
/// addresses, and that the sidebar and Help open the card that sends feedback from inside the app.
final class FeedbackLinksTests: XCTestCase {

    func testTheLinksPointWhereTheySay() {
        XCTAssertEqual(FeedbackLink.newIssue.absoluteString,
                       "https://github.com/my-monkeys/OpenSuperWhisper/issues/new")
        XCTAssertEqual(FeedbackLink.betaBuilds.absoluteString,
                       "https://github.com/my-monkeys/OpenSuperWhisper/releases")
        XCTAssertEqual(FeedbackLink.all.map(\.url), [FeedbackLink.newIssue, FeedbackLink.betaBuilds])
    }

    func testEachLinkHasItsOwnIdentity() {
        XCTAssertEqual(Set(FeedbackLink.all.map(\.id)).count, FeedbackLink.all.count)
        XCTAssertEqual(FeedbackLink.all.map(\.symbol), ["ladybug", "testtube.2"])
    }

    func testTheTitlesAreTheCatalogKeys() {
        XCTAssertEqual(FeedbackLink.all.map(\.title), [
            LocalizedStringKey("Open an issue on GitHub"),
            LocalizedStringKey("Try a beta build"),
        ])
    }

    private func shellSource(_ file: String) throws -> String {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Shell")
        return try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
    }

    /// A second hand-written copy is how the addresses would drift: both places read the shared ones.
    func testHelpAndTheCardShareTheLinks() throws {
        let help = try shellSource("HelpOverlay.swift")
        XCTAssertTrue(help.contains("FeedbackLink.all"), "Help does not draw from the shared list")
        let card = try shellSource("FeedbackOverlay.swift")
        XCTAssertTrue(card.contains("FeedbackLink.newIssue"), "the card lost its GitHub link")
        XCTAssertTrue(card.contains("FeedbackLink.betaBuilds"), "the card lost its beta link")
        for (file, source) in [("HelpOverlay.swift", help), ("FeedbackOverlay.swift", card)] {
            XCTAssertFalse(source.contains("issues/new"), "\(file) keeps its own copy of a feedback link")
        }
    }

    /// The point of the card: feedback is written in the app, not on the website.
    func testTheSidebarAndHelpOpenTheCard() throws {
        XCTAssertTrue(try shellSource("AppSidebar.swift").contains("navigation.openFeedback()"),
                      "the sidebar's Feedback row no longer opens the card")
        XCTAssertTrue(try shellSource("HelpOverlay.swift").contains("navigation.openFeedback()"),
                      "Help no longer offers to send feedback from the app")
        XCTAssertFalse(FeedbackLink.all.contains { $0.url.host == "opensuperwhisper.com" },
                       "the website form came back as the way to send feedback")
    }

    @MainActor
    func testOnlyOneCardIsOpenAtATime() {
        let navigation = AppNavigation.shared
        defer {
            navigation.feedbackOpen = false
            navigation.helpOpen = false
        }
        navigation.helpOpen = true
        navigation.openFeedback()
        XCTAssertFalse(navigation.helpOpen)
        XCTAssertTrue(navigation.feedbackOpen)

        // The settings are a window of their own now, not a card to replace.
        navigation.openSettings(.general)
        XCTAssertTrue(navigation.feedbackOpen, "opening the settings closed Feedback")
    }
}
