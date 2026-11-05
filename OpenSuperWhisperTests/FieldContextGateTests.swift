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
}
