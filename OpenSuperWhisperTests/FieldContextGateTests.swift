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
        scratch.restore()
        scratch = nil
        // The context is a singleton: clear the injected reader and the text a test left on it.
        RecordingContext.shared.focusedTextReader = nil
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

    /// The gate and the capability table can never disagree, for any engine id the build knows.
    /// A new engine that joins `allEngineIds` is covered without touching this file.
    func testTheGateAgreesWithTheCapabilityForEveryEngine() {
        for id in EngineCapabilities.allEngineIds {
            XCTAssertEqual(RecordingContext.wantsFieldText(enabled: true, engine: id),
                           EngineCapabilities.supportsFieldContext(engine: id), id)
        }
    }

    // MARK: - The Settings switch

    /// The switch is offered exactly where the selected engine can use the text. Mutation:
    /// return true unconditionally and the three incapable engines redden.
    ///
    /// This is the layer the review found uncovered: `supportsFieldContext` was tested, the
    /// property the UI actually disables the row with was not.
    func testTheSettingsSwitchIsOfferedOnlyForCapableEngines() {
        let viewModel = SettingsViewModel()

        for id in EngineCapabilities.allEngineIds {
            viewModel.selectedEngine = id
            XCTAssertEqual(viewModel.canUseFieldContext,
                           EngineCapabilities.supportsFieldContext(engine: id), id)
        }

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
    /// the field is read with the setting off.
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
    }
}
