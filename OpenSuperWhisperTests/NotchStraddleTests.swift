import XCTest

@testable import OpenSuperWhisper

/// Laying the bubble out on both sides of the cutout instead of below it.
///
/// The menu bar either side of a notch is usable screen, so that is where the elements go: the
/// waveform to the left of the hardware, the buttons to the right, and nothing growing downward.
final class NotchStraddleTests: XCTestCase {

    private func layout(_ shown: [IndicatorElement]) -> IndicatorLayout {
        IndicatorLayout(order: IndicatorElement.allCases,
                        hidden: Set(IndicatorElement.allCases).subtracting(shown),
                        waveformHeight: IndicatorLayout.defaultWaveformHeight)
    }

    /// The invariant the whole layout rests on. The window is centred and the cutout is centred,
    /// so the gap only lands on the hardware while what flanks it is symmetric — sizing each
    /// side to its own contents would slide the hole off by half the difference.
    func testBothSidesAreTheSameWidthWhateverIsOnThem() {
        let waveformAndButtons = layout([.waveform, .stopButton, .cancelButton])
        let side = waveformAndButtons.notchSideWidth()

        // One number, used for both flanks: the total is symmetric by construction.
        XCTAssertEqual(side, waveformAndButtons.notchSideWidth())
        XCTAssertGreaterThan(side, 0)
    }

    /// The reporter's configuration: a waveform on one side, stop and cancel on the other.
    func testAWaveformAndTwoButtonsBothFit() {
        let side = layout([.waveform, .stopButton, .cancelButton]).notchSideWidth()

        XCTAssertGreaterThanOrEqual(side, 2 * 32 + 8, "two buttons and the gap before them")
        XCTAssertGreaterThanOrEqual(side, 76, "the waveform on the other flank")
    }

    /// Adding a button must never make the side narrower than the buttons need.
    func testMoreButtonsReserveMoreRoom() {
        let one = layout([.waveform, .stopButton]).notchSideWidth()
        let two = layout([.waveform, .stopButton, .cancelButton]).notchSideWidth()
        let three = layout([.stopButton, .cancelButton, .dot]).notchSideWidth()

        XCTAssertLessThanOrEqual(one, two)
        XCTAssertGreaterThanOrEqual(three, 2 * 32 + 8)
    }

    /// A label is prose and needs far more room than a meter; the flank has to grow for it or the
    /// text is clipped against the hardware.
    func testALabelWidensTheFlank() {
        let withoutLabel = layout([.waveform, .stopButton]).notchSideWidth()
        let withLabel = layout([.waveform, .label, .stopButton]).notchSideWidth()

        XCTAssertGreaterThan(withLabel, withoutLabel)
    }

    /// An empty bubble still reserves something: a flank of zero would put the cutout against
    /// the screen edge rather than in the middle.
    func testAnEmptyLayoutStillReservesAFlank() {
        XCTAssertGreaterThanOrEqual(layout([]).notchSideWidth(), 72)
    }

    /// Everything at once still has to be one number for both sides.
    func testTheBusiestLayoutIsStillSymmetric() {
        let everything = layout(IndicatorElement.allCases)

        XCTAssertGreaterThan(everything.notchSideWidth(), 0)
        XCTAssertEqual(everything.notchSideWidth(), everything.notchSideWidth())
    }
}
