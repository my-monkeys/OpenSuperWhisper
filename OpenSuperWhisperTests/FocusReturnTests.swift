import AppKit
import ApplicationServices
import XCTest

@testable import OpenSuperWhisper

/// Covers putting the focus back in the field a dictation started in (#164): when the app is
/// brought back, when only the field is, when nothing is touched, and what happens to the text
/// when the app cannot be reached. Everything runs against a fake system: nothing is activated,
/// focused or pasted on the machine running the tests, and the clipboard used is a private one.
@MainActor
final class FocusReturnTests: XCTestCase {

    private static let targetPID: pid_t = 4242
    private static let otherPID: pid_t = 777

    /// A stand-in for the workspace and Accessibility, scripted per test.
    private final class FakeSystem: FocusControlling {
        var frontmost: [pid_t?]
        var running = true
        var stillFocused: Bool? = false
        var activates = true
        var focuses = true
        /// Who is in front once an accepted activation has settled.
        var frontmostAfterActivation: pid_t? = FocusReturnTests.targetPID
        /// Who is in front once the LaunchServices request has settled.
        var frontmostAfterReopen: pid_t? = FocusReturnTests.targetPID
        /// What the field holds once it has the focus back.
        var field: FieldSnapshot?
        private(set) var selected: [NSRange] = []
        private(set) var calls: [String] = []

        init(frontmost: pid_t?) { self.frontmost = [frontmost] }

        func frontmostPID() -> pid_t? { frontmost.last ?? nil }
        func isRunning(_ target: FocusTarget) -> Bool { calls.append("running"); return running }
        func stillFocused(_ target: FocusTarget) -> Bool? { calls.append("stillFocused"); return stillFocused }
        func activate(_ target: FocusTarget) -> Bool {
            calls.append("activate")
            if activates { frontmost.append(frontmostAfterActivation) }
            return activates
        }
        func reopen(_ target: FocusTarget) -> Bool {
            calls.append("reopen")
            frontmost.append(frontmostAfterReopen)
            return true
        }
        func focus(_ target: FocusTarget) -> Bool { calls.append("focus"); return focuses }
        func field(_ target: FocusTarget) -> FieldSnapshot? { calls.append("field"); return field }
        func select(_ range: NSRange, in target: FocusTarget) { calls.append("select"); selected.append(range) }
        func settle() async { calls.append("settle") }
    }

    /// An element is only compared and handed back to the fake, never messaged: creating one
    /// asks nothing of the app it names.
    private func target(withField: Bool = true, field: FieldSnapshot? = nil) -> FocusTarget {
        FocusTarget(pid: Self.targetPID, bundleID: "com.example.notes",
                    element: withField ? AXUIElementCreateApplication(Self.targetPID) : nil,
                    field: field)
    }

    // MARK: - Another app in front

    func testTheAppAndTheFieldAreBroughtBackBeforeInserting() async {
        let system = FakeSystem(frontmost: Self.otherPID)

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .refocused)
        XCTAssertEqual(system.calls, ["running", "activate", "focus", "field", "settle"])
    }

    /// Chrome and Electron often say nothing about their focused element: the app is still
    /// worth bringing back.
    func testAnAppThatDidNotNameItsFieldIsStillBroughtBack() async {
        let system = FakeSystem(frontmost: Self.otherPID)

        let outcome = await FocusReturn.bringBack(target(withField: false), using: system)

        XCTAssertEqual(outcome, .appOnly)
        XCTAssertEqual(system.calls, ["running", "activate", "settle"])
    }

    func testAClosedFieldFallsBackToTheApp() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.focuses = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .appOnly)
    }

    func testAnAppThatQuitIsNotReplacedByWhateverIsInFront() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.running = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(system.calls, ["running"])
    }

    func testARefusedActivationLeavesNothingToInsertInto() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.activates = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertFalse(system.calls.contains("focus"))
    }

    /// An activation the system accepted but never carried out, and a LaunchServices request
    /// that did no better, would otherwise paste into the app the user moved to.
    func testAnActivationThatDidNotHappenIsCaughtBeforeInserting() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.frontmostAfterActivation = Self.otherPID
        system.frontmostAfterReopen = Self.otherPID

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(system.calls.filter { $0 == "reopen" }.count, 1)
    }

    /// Dia answers the accessibility request with a success and stays behind: LaunchServices
    /// brings it forward, and the field gets the focus once it is in front.
    func testAnAppThatIgnoredTheActivationIsReopenedAndRefocused() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.frontmostAfterActivation = Self.otherPID

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .refocused)
        XCTAssertEqual(system.calls, ["running", "activate", "focus", "field", "settle",
                                      "reopen", "settle", "focus", "field", "settle"])
    }

    /// An app that came forward on the first request gets no reopen event, which would make one
    /// with no window open a new one.
    func testAnAppThatCameForwardIsNotReopened() async {
        let system = FakeSystem(frontmost: Self.otherPID)

        _ = await FocusReturn.bringBack(target(), using: system)

        XCTAssertFalse(system.calls.contains("reopen"))
    }

    // MARK: - Same app in front

    func testNothingIsTouchedWhenTheFocusNeverLeft() async {
        let system = FakeSystem(frontmost: Self.targetPID)
        system.stillFocused = true

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertEqual(system.calls, ["running", "stillFocused"])
    }

    /// No answer is no evidence of a move: the app behaves as it did before this feature.
    func testAnAppThatCannotSayWhereTheFocusIsIsLeftAlone() async {
        let system = FakeSystem(frontmost: Self.targetPID)
        system.stillFocused = nil

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertFalse(system.calls.contains("focus"))
    }

    func testAnotherFieldOfTheSameAppGivesTheFocusBack() async {
        let system = FakeSystem(frontmost: Self.targetPID)

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .refocused)
        XCTAssertEqual(system.calls, ["running", "stillFocused", "focus", "field", "settle"])
    }

    func testTheSameAppWithoutANamedFieldIsLeftAlone() async {
        let system = FakeSystem(frontmost: Self.targetPID)

        let outcome = await FocusReturn.bringBack(target(withField: false), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertFalse(system.calls.contains("activate"))
    }

    // MARK: - The caret

    private static func field(_ count: Int, _ location: Int, _ length: Int = 0) -> FieldSnapshot {
        FieldSnapshot(characterCount: count, selection: NSRange(location: location, length: length))
    }

    func testTheCaretIsPutBackInAFieldNothingWasWrittenTo() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.field = Self.field(50, 0, 50)

        _ = await FocusReturn.bringBack(target(field: Self.field(50, 10)), using: system)

        XCTAssertEqual(system.selected, [NSRange(location: 10, length: 0)])
    }

    /// Two dictations started at the same caret in the same field, the second before the first
    /// was inserted. The user moves away after each. The second must land after the first, not
    /// at the caret they shared, which is now before it.
    func testASecondDictationInTheSameFieldLandsAfterTheFirst() async {
        let atRecordStart = Self.field(50, 10)
        let first = target(field: atRecordStart)
        let second = target(field: atRecordStart)
        let system = FakeSystem(frontmost: Self.otherPID)
        system.field = Self.field(50, 0, 50)

        _ = await FocusReturn.bringBack(first, using: system)
        // The first text (5 characters) went in at its caret, then the user moved away again.
        system.frontmost.append(Self.otherPID)
        system.field = Self.field(55, 15)
        _ = await FocusReturn.bringBack(second, using: system)

        XCTAssertEqual(system.selected, [NSRange(location: 10, length: 0)],
                       "the field keeps its own caret, after the first text")
    }

    /// A text field that regains the focus selects everything, and a stale caret cannot be
    /// trusted to undo that: the paste would replace the whole field.
    func testAChangedFieldThatSelectedEverythingIsNotReplaced() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.field = Self.field(55, 0, 55)

        _ = await FocusReturn.bringBack(target(field: Self.field(50, 10, 5)), using: system)

        XCTAssertEqual(system.selected, [NSRange(location: 55, length: 0)])
    }

    func testTheSelectionDecision() {
        typealias F = FocusReturnTests
        XCTAssertEqual(FocusReturn.selectionToSet(captured: F.field(50, 10, 3), now: F.field(50, 0, 50)),
                       NSRange(location: 10, length: 3), "unchanged field: the selection comes back")
        XCTAssertNil(FocusReturn.selectionToSet(captured: F.field(50, 10), now: F.field(50, 10)),
                     "already there: nothing to set")
        XCTAssertNil(FocusReturn.selectionToSet(captured: F.field(50, 10), now: F.field(52, 30)),
                     "changed field: its own caret stays")
        XCTAssertEqual(FocusReturn.selectionToSet(captured: nil, now: F.field(52, 0, 52)),
                       NSRange(location: 52, length: 0), "unknown start: a full selection still collapses")
        XCTAssertNil(FocusReturn.selectionToSet(captured: nil, now: F.field(0, 0)), "an empty field")
        XCTAssertNil(FocusReturn.selectionToSet(captured: F.field(50, 10), now: nil),
                     "a field that will not say is left alone")
    }

    // MARK: - Delivery

    private final class DeliveryLog {
        var broughtBack = 0
        var held: [Bool] = []
        var inserted = 0
    }

    private func deliver(_ outcome: FocusReturn.Outcome, target: FocusTarget? = nil,
                         returningFocus: Bool = true, warn: Bool = true, keepOnClipboard: Bool = false,
                         insertFindsNoField: Bool = false,
                         log: DeliveryLog) async -> DictationPipeline.Delivery {
        await DictationPipeline.deliver(
            to: target ?? self.target(), returningFocus: returningFocus, warn: warn,
            keepOnClipboard: keepOnClipboard,
            bringBack: { _ in log.broughtBack += 1; return outcome },
            hold: { log.held.append($0) },
            insert: { log.inserted += 1; return insertFindsNoField ? .onClipboardAnnounced : .inserted })
    }

    func testAReturnedFocusIsFollowedByTheUsualInsertion() async {
        let log = DeliveryLog()

        let delivery = await deliver(.refocused, log: log)

        XCTAssertEqual(delivery, .inserted)
        XCTAssertEqual(log.broughtBack, 1)
        XCTAssertEqual(log.inserted, 1)
        XCTAssertEqual(log.held, [])
    }

    func testTheUsualInsertionStillReportsAMissingField() async {
        let log = DeliveryLog()

        let delivery = await deliver(.appOnly, insertFindsNoField: true, log: log)

        XCTAssertEqual(delivery, .onClipboardAnnounced)
    }

    func testWithTheSettingOffTheFocusIsNotTouched() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, returningFocus: false, log: log)

        XCTAssertEqual(delivery, .inserted)
        XCTAssertEqual(log.broughtBack, 0)
        XCTAssertEqual(log.inserted, 1)
    }

    func testAnUnreachableAppGetsTheClipboardAndTheNotice() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, log: log)

        XCTAssertEqual(delivery, .onClipboardAnnounced)
        XCTAssertEqual(log.inserted, 0, "never inserted into whatever is in front instead")
        XCTAssertEqual(log.held, [true])
    }

    /// Unannounced, the clipboard is not replaced: the paste-last shortcut has the text.
    func testAnUnreachableAppWithTheWarningOffKeepsTheClipboard() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, warn: false, log: log)

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(log.inserted, 0)
        XCTAssertEqual(log.held, [false])
    }

    func testAnUnreachableAppStillLeavesItOnTheClipboardWhenThatIsTheSetting() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, warn: false, keepOnClipboard: true, log: log)

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(log.held, [true])
    }

    /// A dictation that is only "press enter" must not press it in the app the user moved to.
    func testASubmitOnlyDictationIsNotPressedIntoAnotherApp() async {
        let unreachable = await DictationPipeline.deliverSubmitOnly(
            to: target(), returningFocus: true, bringBack: { _ in .unreachable })
        let broughtBack = await DictationPipeline.deliverSubmitOnly(
            to: target(), returningFocus: true, bringBack: { _ in .refocused })

        XCTAssertEqual(unreachable, .held, "no Return")
        XCTAssertEqual(broughtBack, .inserted, "Return, in the app it started in")
    }

    // MARK: - Remembering the field

    func testTheFieldIsRememberedOnlyWhenTheTextWillGoBackToIt() {
        func wants(front: String? = "com.example.notes", autoPaste: Bool = true, setting: Bool = true) -> Bool {
            RecordingContext.wantsFocusTarget(frontBundleID: front, ownBundleID: "com.example.osw",
                                              autoPaste: autoPaste, pasteIntoOriginalField: setting)
        }
        XCTAssertTrue(wants())
        XCTAssertFalse(wants(front: "com.example.osw"), "our own window is never sent elsewhere")
        XCTAssertFalse(wants(front: nil))
        XCTAssertFalse(wants(setting: false))
        XCTAssertFalse(wants(autoPaste: false), "nothing would be pasted back")
    }

    // MARK: - Holding the text

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        TranscriptInserter.noteNewerTranscription()
    }

    override func tearDown() {
        TranscriptInserter.noteNewerTranscription()
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testHeldTextReachesThePasteLastShortcut() {
        TranscriptInserter.holdUndelivered("dictation", onClipboard: false, pasteboard: pasteboard)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "dictation")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testHeldTextGoesOnTheClipboardWhenAsked() {
        TranscriptInserter.holdUndelivered("dictation", onClipboard: true, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "dictation")
    }
}
