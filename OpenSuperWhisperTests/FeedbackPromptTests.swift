import XCTest

@testable import OpenSuperWhisper

/// When the app asks, once per campaign, for feedback (#206): never twice, never during the
/// launch that runs onboarding, and never over a dictation or another card.
final class FeedbackPromptTests: XCTestCase {

    /// A moment where everything allows it.
    private let ready = FeedbackPrompt.Moment(
        done: false, onboardedAtLaunch: true, windowInFront: true, onQuietHome: true,
        cardOpen: false, busy: false)

    func testItAsksWhenEverythingAllowsIt() {
        XCTAssertTrue(FeedbackPrompt.shouldAsk(ready))
    }

    func testEachConditionAloneHoldsItBack() {
        let blockers: [(String, (inout FeedbackPrompt.Moment) -> Void)] = [
            ("already asked, or feedback sent", { $0.done = true }),
            ("the launch that ran onboarding", { $0.onboardedAtLaunch = false }),
            ("the window not in front", { $0.windowInFront = false }),
            ("another page, or a search", { $0.onQuietHome = false }),
            ("another card open", { $0.cardOpen = true }),
            ("a dictation or a transcription", { $0.busy = true }),
        ]
        for (reason, block) in blockers {
            var moment = ready
            block(&moment)
            XCTAssertFalse(FeedbackPrompt.shouldAsk(moment), "asked despite \(reason)")
        }
    }

    /// Whoever answered the interface question of 0.14, or never saw a prompt, is asked again:
    /// only this campaign's own answer counts.
    func testOnlyThisCampaignsAnswerCounts() {
        XCTAssertFalse(FeedbackPrompt.isDone(stored: nil))
        XCTAssertFalse(FeedbackPrompt.isDone(stored: "an-earlier-campaign"))
        XCTAssertTrue(FeedbackPrompt.isDone(stored: FeedbackPrompt.campaign))
    }
}

/// What asking does to the preferences and the main window.
@MainActor
final class FeedbackPromptAskTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private var navigation: AppNavigation { .shared }

    override func setUp() async throws {
        scratch = ScratchPreferences()
    }

    override func tearDown() async throws {
        navigation.feedbackOpen = false
        navigation.helpOpen = false
        scratch.restore()
    }

    func testAskingRecordsItBeforeAnythingElse() {
        let prefs = AppPreferences.shared
        XCTAssertNil(prefs.feedbackPromptCampaign)
        FeedbackPromptScheduler.ask(prefs: prefs, navigation: navigation)
        XCTAssertEqual(prefs.feedbackPromptCampaign, FeedbackPrompt.campaign,
                       "a quit with the card up would ask again")
        XCTAssertTrue(navigation.feedbackOpen)
        XCTAssertTrue(navigation.feedbackAsked)
    }

    func testClosingTheAskedCardEndsTheAskedMode() {
        FeedbackPromptScheduler.ask(prefs: .shared, navigation: navigation)
        navigation.feedbackOpen = false
        XCTAssertFalse(navigation.feedbackAsked)
        navigation.openFeedback()
        XCTAssertFalse(navigation.feedbackAsked, "the sidebar's card came back with the note")
    }

    func testTheSidebarOpensTheUsualCardOverTheAskedOne() {
        FeedbackPromptScheduler.ask(prefs: .shared, navigation: navigation)
        navigation.openFeedback()
        XCTAssertTrue(navigation.feedbackOpen)
        XCTAssertFalse(navigation.feedbackAsked)
    }

    func testSendingFeedbackAnywhereEndsTheAsk() {
        XCTAssertNil(AppPreferences.shared.feedbackPromptCampaign)
        FeedbackPrompt.markDone()
        XCTAssertEqual(AppPreferences.shared.feedbackPromptCampaign, FeedbackPrompt.campaign)
    }
}
