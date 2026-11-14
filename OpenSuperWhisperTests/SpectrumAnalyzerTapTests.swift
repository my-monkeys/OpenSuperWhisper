import AVFoundation
import CoreAudio
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

    /// What building one engine per take relies on: a new engine reads from the device that is
    /// the default input at that moment, which `AudioRecorder` has just made the take's mic. The
    /// engine is never started, so no microphone is opened; reading `inputNode` only creates the
    /// I/O unit.
    func testAFreshEngineReadsTheCurrentDefaultInput() throws {
        guard let defaultInput = MicrophoneService.shared.getCurrentSystemDefaultInputDevice(),
              defaultInput != kAudioObjectUnknown
        else { throw XCTSkip("no input device on this machine") }

        let engine = AVAudioEngine()
        let devices = SpectrumAnalyzer.devicesBehindInput(of: engine)

        let unitDevice = engine.inputNode.auAudioUnit.deviceID
        XCTAssertTrue(devices.contains(defaultInput),
                      "input on \(devices) (unit device \(unitDevice)), default \(defaultInput)")
    }

    /// The engine is built off the main thread, so a stop can land before the build reports back:
    /// only the build of the latest take may mark the analyzer as running.
    func testOnlyTheLatestTakesBuildIsCurrent() {
        XCTAssertTrue(SpectrumAnalyzer.isCurrent(build: 3, latest: 3))
        XCTAssertFalse(SpectrumAnalyzer.isCurrent(build: 3, latest: 4), "stopped meanwhile")
        XCTAssertFalse(SpectrumAnalyzer.isCurrent(build: 3, latest: 5), "stopped and restarted")
    }
}
