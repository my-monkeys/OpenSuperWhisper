import XCTest

@testable import OpenSuperWhisper

/// When the visualiser's microphone tap should exist at all.
///
/// It is a second claim on the input device, opened immediately after `AVAudioRecorder` has taken
/// it, which is exactly when a route or format reconfiguration is in flight. Reported on 0.12.3:
/// the tap was refused for a format mismatch and CoreAudio then failed to start the input at all,
/// repeatedly. The cheapest half of the fix is not to open it when nothing reads it.
final class SpectrumAnalyzerTapTests: XCTestCase {

    private func layout(_ shown: [IndicatorElement]) -> IndicatorLayout {
        IndicatorLayout(order: IndicatorElement.allCases,
                        hidden: Set(IndicatorElement.allCases).subtracting(shown),
                        waveformHeight: IndicatorLayout.defaultWaveformHeight)
    }

    func testTheTapRunsWhenTheWaveformIsShown() {
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: layout([.waveform])))
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: layout([.waveform, .label, .stopButton])))
    }

    /// The whole point: no visualiser, no second tap, no exposure to the race.
    func testTheTapDoesNotRunWithoutTheWaveform() {
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([.dot, .label])))
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([])))
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([.stopButton, .cancelButton])))
    }

    /// The transcribing row borrows the meter to carry a spinner when the layout has neither
    /// meter nor label. That spinner draws nothing from the microphone, so it must not be read as
    /// a reason to open a tap.
    func testTheBorrowedSpinnerIsNotAReasonToTap() {
        let dotOnly = layout([.dot])

        XCTAssertTrue(dotOnly.decodingLeading.contains(.waveform),
                      "this layout is the one that borrows the meter")
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: dotOnly))
    }

    /// The default layout does show the meter, so nobody loses the visualiser to this.
    func testTheDefaultLayoutStillGetsItsMeter() {
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: .default))
    }
}
