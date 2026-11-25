import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The two gates above the capability table, which decide whether the focused field is read at
/// all (#89, #F2).
///
/// The core suite pins `supportsFieldContext`; nothing pinned the layers that call it. Each
/// conjunct is asserted alone here, because neither the user's switch nor a capable engine is on
/// its own a reason to read someone's document.
@MainActor
final class FieldContextGateTests: XCTestCase {

    private var scratch: ScratchPreferences!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        // The context is a singleton and `focusedText` has no setter — `update` deliberately
        // leaves it alone (#F4) — so the text a test left is cleared the only way it is ever
        // written: `captureFocusedText` with the gate closed, which assigns nil without an
        // Accessibility read. Before the restore, so the closed gate is the scratch state and
        // not whatever this machine happens to have.
        RecordingContext.shared.focusedTextReader = nil
        AppPreferences.shared.useSurroundingTextAsContext = false
        RecordingContext.shared.captureFocusedText()

        scratch.restore()
        scratch = nil
        RecordingContext.shared.update(appName: nil, bundleID: nil)
        super.tearDown()
    }

    // MARK: - The read gate

    /// Both conjuncts, each with a case of its own.
    ///
    /// Mutations: flipping `&&` to `||` reddens the first two assertions; dropping the `enabled`
    /// conjunct reddens the first; dropping the engine conjunct reddens the third.
    func testTheReadNeedsBothTheSwitchAndACapableEngine() {
        XCTAssertFalse(RecordingContext.wantsFieldText(enabled: false, engine: "whisper"),
                       "the switch is off and the engine is capable — the field must not be read")
        XCTAssertFalse(RecordingContext.wantsFieldText(enabled: true, engine: "sensevoice"),
                       "the switch is on and the engine takes nothing — the field must not be read")
        XCTAssertFalse(RecordingContext.wantsFieldText(enabled: true, engine: "remote"),
                       "remote is refused on purpose, not for want of an input")
        XCTAssertTrue(RecordingContext.wantsFieldText(enabled: true, engine: "whisper"))
        XCTAssertTrue(RecordingContext.wantsFieldText(enabled: true, engine: "fluidaudio"))
    }

    /// The gate's answer per engine, as literals rather than as a re-derivation of its own
    /// implementation. Mutation: `||` instead of `&&`, a special case for remote, or a dropped
    /// conjunct changes one of these answers and reddens here. (An engine id the table does not
    /// know is refused, which is what keeps a new id from opening the gate by accident.)
    func testTheGateAnswersFromItsOwnRuleForEveryKnownEngine() {
        let expected: [String: Bool] = ["whisper": true, "fluidaudio": true,
                                        "remote": false, "apple": false, "sensevoice": false,
                                        "groq": false, "": false]
        for (engine, answer) in expected {
            XCTAssertEqual(RecordingContext.wantsFieldText(enabled: true, engine: engine),
                           answer, engine)
            XCTAssertFalse(RecordingContext.wantsFieldText(enabled: false, engine: engine), engine)
        }
    }

    // MARK: - The Settings switch

    /// The switch is offered exactly where the selected engine can use the text, as literals.
    /// Mutation: return true unconditionally and the three incapable engines redden; mark remote
    /// capable and the remote row reddens.
    ///
    /// This is the layer the review found uncovered: `supportsFieldContext` was tested, the
    /// property the UI actually disables the row with was not. The expectations are hardcoded on
    /// purpose — a loop comparing the property to the capability table would be the same
    /// expression twice and could never fail.
    func testTheSettingsSwitchIsOfferedOnlyForCapableEngines() {
        let viewModel = SettingsViewModel()

        viewModel.selectedEngine = "whisper"
        XCTAssertTrue(viewModel.canUseFieldContext)
        viewModel.selectedEngine = "fluidaudio"
        XCTAssertTrue(viewModel.canUseFieldContext)
        viewModel.selectedEngine = "remote"
        XCTAssertFalse(viewModel.canUseFieldContext, "remote would post the text to a server")
        viewModel.selectedEngine = "sensevoice"
        XCTAssertFalse(viewModel.canUseFieldContext)
        viewModel.selectedEngine = "apple"
        XCTAssertFalse(viewModel.canUseFieldContext)
    }

    // MARK: - The read itself

    /// The matched pair the injected reader exists for.
    ///
    /// Without it both branches produce nil in a headless process — the guard firing and the
    /// Accessibility read failing look identical — so "the field was not read" would pass for the
    /// wrong reason. The positive control is what turns the negative into evidence.
    ///
    /// Mutation: remove the gate from `captureFocusedText` and the negative case reads.
    func testTheFieldIsNotReadForAnEngineThatCannotUseIt() {
        let prefs = AppPreferences.shared
        let context = RecordingContext.shared
        prefs.useSurroundingTextAsContext = true

        var reads = 0
        context.focusedTextReader = { reads += 1; return "a private sentence" }

        // Refused on purpose: the text would leave the machine.
        prefs.selectedEngine = "remote"
        context.captureFocusedText()
        XCTAssertEqual(reads, 0, "the field was read for an engine that must never see it")
        XCTAssertNil(context.focusedText)

        // The same call under a capable engine does read — without this, the assertion above
        // would pass just as well if the reader were never wired up at all.
        prefs.selectedEngine = "whisper"
        context.captureFocusedText()
        XCTAssertEqual(reads, 1, "the reader was never called: the negative case above is vacuous")
        XCTAssertEqual(context.focusedText, "a private sentence")
    }

    /// The switch's conjunct, behaviourally. Mutation: drop `enabled` from `wantsFieldText` and
    /// the first assertion reddens.
    ///
    /// The positive control is inside the row: the same seam must read once the switch is on, or
    /// the negative half would pass equally with a reader that was never wired up.
    func testTheFieldIsNotReadWithTheSwitchOff() {
        let prefs = AppPreferences.shared
        let context = RecordingContext.shared
        prefs.useSurroundingTextAsContext = false
        prefs.selectedEngine = "whisper"

        var reads = 0
        context.focusedTextReader = { reads += 1; return "a private sentence" }

        context.captureFocusedText()

        XCTAssertEqual(reads, 0)
        XCTAssertNil(context.focusedText)

        prefs.useSurroundingTextAsContext = true
        context.captureFocusedText()
        XCTAssertEqual(reads, 1, "the reader was never called: the negative case above is vacuous")
    }

    /// F4: opening the status-bar menu mid-recording refreshes the app fields and must leave the
    /// text the recording captured alone. `captureFrontmost(forRecording: false)` is the only
    /// caller that needs the app without the field, and `update` deliberately has no parameter
    /// for the text.
    ///
    /// Mutation: assign `focusedText = nil` in `captureFrontmost` (or in its
    /// `forRecording: false` branch) and the second assertion reddens — the clip would then be
    /// transcribed with no field context, which is F4 with a new mechanism.
    func testTheMenuPathLeavesTheRecordedFieldTextAlone() {
        let prefs = AppPreferences.shared
        let context = RecordingContext.shared
        prefs.useSurroundingTextAsContext = true
        prefs.selectedEngine = "whisper"
        context.focusedTextReader = { "a private sentence" }
        context.captureFocusedText()
        XCTAssertEqual(context.focusedText, "a private sentence", "the record-start read failed")

        context.captureFrontmost(forRecording: false)

        XCTAssertEqual(context.focusedText, "a private sentence",
                       "the menu path erased the field text the recording captured")
    }
}
