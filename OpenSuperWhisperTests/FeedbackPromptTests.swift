import XCTest

@testable import OpenSuperWhisper

/// When the app asks, once, for feedback on the new interface (#206): never twice, never before
/// the interface has been used, never over a dictation or another card, and never on its own
/// launch in the menu bar.
final class FeedbackPromptTests: XCTestCase {

    /// A moment where everything allows it.
    private let ready = FeedbackPrompt.Moment(
        done: false, launches: FeedbackPrompt.minimumLaunches, onboardedAtLaunch: true,
        startedHidden: false, windowInFront: true, onQuietHome: true, cardOpen: false, busy: false)

    func testItAsksWhenEverythingAllowsIt() {
        XCTAssertTrue(FeedbackPrompt.shouldAsk(ready))
    }

    func testEachConditionAloneHoldsItBack() {
        let blockers: [(String, (inout FeedbackPrompt.Moment) -> Void)] = [
            ("already asked, or feedback sent", { $0.done = true }),
            ("too few launches", { $0.launches = FeedbackPrompt.minimumLaunches - 1 }),
            ("the launch that ran onboarding", { $0.onboardedAtLaunch = false }),
            ("a launch in the menu bar", { $0.startedHidden = true }),
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

    func testMoreLaunchesStillAsk() {
        var moment = ready
        moment.launches = FeedbackPrompt.minimumLaunches + 5
        XCTAssertTrue(FeedbackPrompt.shouldAsk(moment))
    }

    func testOnlyLaunchesThatStartedOnboardedCount() {
        XCTAssertEqual(FeedbackPrompt.launches(after: 0, onboardedAtLaunch: false), 0)
        XCTAssertEqual(FeedbackPrompt.launches(after: 0, onboardedAtLaunch: true), 1)
    }

    func testTheCountStopsAtTheMinimum() {
        let minimum = FeedbackPrompt.minimumLaunches
        XCTAssertEqual(FeedbackPrompt.launches(after: minimum, onboardedAtLaunch: true), minimum)
        XCTAssertEqual(FeedbackPrompt.launches(after: minimum + 3, onboardedAtLaunch: true), minimum,
                       "a count written by a build with a higher minimum was left growing")
    }

    /// A fresh install: onboarding on the first launch, the window used on the second, asked on
    /// the third at the earliest.
    func testAFreshInstallIsAskedOnItsThirdLaunchAtTheEarliest() {
        var count = 0
        var askedOn: Int?
        for (launch, onboarded) in [(1, false), (2, true), (3, true), (4, true)] {
            count = FeedbackPrompt.launches(after: count, onboardedAtLaunch: onboarded)
            var moment = ready
            moment.launches = count
            moment.onboardedAtLaunch = onboarded
            if askedOn == nil, FeedbackPrompt.shouldAsk(moment) { askedOn = launch }
        }
        XCTAssertEqual(askedOn, 3)
    }

    /// Someone updating from 0.13 was onboarded long ago: their first launch of this version is
    /// their first look at the new interface, so they are asked on the next one.
    func testAnUpdateIsAskedOnItsSecondLaunch() {
        let first = FeedbackPrompt.launches(after: 0, onboardedAtLaunch: true)
        var moment = ready
        moment.launches = first
        XCTAssertFalse(FeedbackPrompt.shouldAsk(moment))
        moment.launches = FeedbackPrompt.launches(after: first, onboardedAtLaunch: true)
        XCTAssertTrue(FeedbackPrompt.shouldAsk(moment))
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
        XCTAssertFalse(prefs.feedbackPromptDone)
        FeedbackPromptScheduler.ask(prefs: prefs, navigation: navigation)
        XCTAssertTrue(prefs.feedbackPromptDone, "a quit with the card up would ask again")
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
        XCTAssertFalse(AppPreferences.shared.feedbackPromptDone)
        FeedbackPrompt.markDone()
        XCTAssertTrue(AppPreferences.shared.feedbackPromptDone)
    }

    /// The hosted tests draw the main window too: in a test process nothing is ever recorded,
    /// so nothing is ever asked.
    func testATestProcessNeverCountsALaunch() {
        FeedbackPromptScheduler.shared.recordLaunch(onboarded: true, startedHidden: false)
        XCTAssertEqual(AppPreferences.shared.feedbackPromptLaunches, 0)
    }
}
