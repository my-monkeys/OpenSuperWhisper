import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The bubble's geometry on a Mac that has a cutout.
///
/// Three attempts at this were judged by eye and rejected, so the invariants that survived are
/// written down here: one width whatever the bubble is showing, never narrower than the hardware,
/// symmetric flanks, and an entrance that starts inside the notch rather than above it.
final class NotchGeometryTests: XCTestCase {

    private let cutout = CGSize(width: 220, height: 38)

    private func layout(_ shown: [IndicatorElement]) -> IndicatorLayout {
        IndicatorLayout(order: IndicatorElement.allCases,
                        hidden: Set(IndicatorElement.allCases).subtracting(shown),
                        waveformHeight: IndicatorLayout.defaultWaveformHeight)
    }

    private func geometry(_ shown: [IndicatorElement], textScale: CGFloat = 1,
                          topRadius: CGFloat = 10) -> NotchGeometry {
        NotchGeometry.measure(cutout: cutout, layout: layout(shown), textScale: textScale,
                              topRadius: topRadius, bottomRadius: 14)!
    }

    // MARK: - There has to be hardware

    /// The whole point of the optional. A screen without a cutout draws a pill because someone
    /// liked the look, and measurements taken off a MacBook have no business shaping it: that
    /// confusion is what hung a 42pt pill from the top of a screen whose top 38pt are a hole.
    func testNoCutoutMeansNoGeometry() {
        XCTAssertNil(NotchGeometry.measure(cutout: nil, layout: layout([.waveform]),
                                           textScale: 1, topRadius: 10, bottomRadius: 14))
    }

    func testADegenerateCutoutIsNotHardwareEither() {
        XCTAssertNil(NotchGeometry(cutout: CGSize(width: 220, height: 0), sideWidth: 80,
                                   topRadius: 10, bottomRadius: 14))
        XCTAssertNil(NotchGeometry(cutout: CGSize(width: 0, height: 38), sideWidth: 80,
                                   topRadius: 10, bottomRadius: 14))
    }

    // MARK: - Never narrower than the notch

    /// `NotchShape` pulls its top corners inward by `topRadius`, so at the height of the cutout it
    /// draws `width - 2 * topRadius`. A pill merely as wide as the hardware therefore leaves the
    /// glass showing past both edges.
    func testTheDrawnWidthAtCutoutLevelCoversTheHardware() {
        for topRadius in [CGFloat(0), 6, 10, 22] {
            let drawnAtCutoutLevel = geometry([], topRadius: topRadius).width - 2 * topRadius

            XCTAssertGreaterThanOrEqual(drawnAtCutoutLevel, cutout.width,
                                        "a \(topRadius)pt wing must not eat into the notch")
        }
    }

    /// Even the emptiest possible bubble. The floor is structural, not a consequence of having
    /// something to show.
    func testAnEmptyBubbleIsStillAtLeastAsWideAsTheNotch() {
        XCTAssertGreaterThanOrEqual(geometry([]).width, cutout.width)
    }

    // MARK: - One width, every state

    /// The rejected versions computed the width from what was on screen at that instant, so
    /// showing a caption made the bubble *narrower* while it grew taller. Nothing about the
    /// state reaches this type: the same layout gives the same width, full stop.
    func testTheWidthDoesNotDependOnWhatIsBeingShown() {
        let recording = geometry([.waveform, .stopButton, .cancelButton])
        let same = geometry([.waveform, .stopButton, .cancelButton])

        XCTAssertEqual(recording.width, same.width)
        XCTAssertEqual(recording.sideWidth, same.sideWidth)
    }

    /// A layout with neither meter nor label borrows the meter to carry the transcribing spinner,
    /// so the flank has to be sized for that too. Sizing it for the recording row alone made the
    /// bubble jump wider the moment the user stopped talking.
    func testTheFlankCoversTranscribingAsWellAsRecording() {
        let dotOnly = layout([.dot])
        let flank = NotchGeometry.flankWidth(for: dotOnly, textScale: 1)
        let transcribingRow = NotchGeometry.rowWidth(dotOnly.decodingLeading, textScale: 1)

        XCTAssertGreaterThan(dotOnly.decodingLeading.count, dotOnly.leading.count,
                             "this layout is the one that borrows the meter")
        XCTAssertGreaterThanOrEqual(flank, transcribingRow)
    }

    // MARK: - Symmetry

    /// The window is centred and so is the cutout, so the hole only lands on the glass while the
    /// two flanks match. Sizing each side to its own contents would slide it off by half the
    /// difference.
    func testTheFlanksAreOneNumberUsedTwice() {
        let lopsided = geometry([.waveform, .stopButton, .cancelButton])

        XCTAssertEqual(lopsided.sideWidth * 2 + lopsided.cutout.width, lopsided.width, accuracy: 0.001,
                       "nothing but the two flanks and the hardware between them")
    }

    /// Reserving less than an element draws clips it against the hardware.
    func testEachFlankHoldsWhatItHasToDraw() {
        let busy = layout([.waveform, .label, .stopButton, .cancelButton])
        let flank = NotchGeometry.flankWidth(for: busy, textScale: 1)

        XCTAssertGreaterThanOrEqual(flank, NotchGeometry.rowWidth(busy.leading, textScale: 1))
        XCTAssertGreaterThanOrEqual(flank, NotchGeometry.rowWidth(busy.trailing, textScale: 1))
    }

    func testALabelWidensTheFlank() {
        XCTAssertGreaterThan(geometry([.waveform, .label]).sideWidth,
                             geometry([.waveform]).sideWidth)
    }

    /// The bubble is nearly all graphics, so the text setting has to move its dimensions too.
    func testALargerTextSettingWidensTheFlank() {
        XCTAssertGreaterThan(geometry([.label], textScale: 1.6).sideWidth,
                             geometry([.label], textScale: 1).sideWidth)
    }

    // MARK: - Height

    /// A floor *and* a ceiling. Content that grew past it would spill out from under the notch,
    /// which is exactly the block the earlier attempt produced.
    func testTheBandIsExactlyTheCutoutsHeight() {
        XCTAssertEqual(geometry([.waveform, .label]).bandHeight, cutout.height)
    }

    // MARK: - The entrance

    /// At rest the mask is the cutout and nothing else, so the first frame is hidden behind the
    /// hardware and the bubble looks like it grew out of it.
    func testTheRevealStartsInsideTheNotch() {
        let full = CGRect(x: 0, y: 0, width: 520, height: 90)
        let closed = NotchReveal(progress: 0, cutout: cutout, topRadius: 10, bottomRadius: 14)
            .path(in: full).boundingRect

        XCTAssertEqual(closed.width, cutout.width, accuracy: 0.001)
        XCTAssertEqual(closed.height, cutout.height, accuracy: 0.001)
        XCTAssertEqual(closed.midX, full.midX, accuracy: 0.001, "centred on the hardware")
        XCTAssertEqual(closed.minY, full.minY, accuracy: 0.001, "and pinned to the top edge")
    }

    /// Fully open it is the bubble itself, so the mask doubles as the silhouette and nothing is
    /// left clipped.
    func testTheRevealEndsAsTheWholeBubble() {
        let full = CGRect(x: 0, y: 0, width: 520, height: 90)
        let open = NotchReveal(progress: 1, cutout: cutout, topRadius: 10, bottomRadius: 14)
            .path(in: full).boundingRect
        let silhouette = NotchShape(topRadius: 10, bottomRadius: 14).path(in: full).boundingRect

        XCTAssertEqual(open, silhouette)
    }

    /// It only ever widens, and it stays centred the whole way. The version this replaces scaled
    /// the view tree, which moved the content as well as revealing it.
    func testTheRevealOnlyGrowsAndStaysCentred() {
        let full = CGRect(x: 0, y: 0, width: 520, height: 90)
        var previous: CGFloat = 0

        for step in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let box = NotchReveal(progress: step, cutout: cutout, topRadius: 10, bottomRadius: 14)
                .path(in: full).boundingRect

            XCTAssertGreaterThanOrEqual(box.width, previous)
            XCTAssertEqual(box.midX, full.midX, accuracy: 0.001)
            XCTAssertEqual(box.minY, full.minY, accuracy: 0.001)
            previous = box.width
        }
    }

    /// Out of range values cannot make the mask larger than the bubble or narrower than the
    /// notch: a spring overshoots past 1, and an overshoot that widened the mask past the pill
    /// would show a black rectangle for a frame.
    func testAnOvershootingSpringCannotBreakTheMask() {
        let full = CGRect(x: 0, y: 0, width: 520, height: 90)
        let over = NotchReveal(progress: 1.3, cutout: cutout, topRadius: 10, bottomRadius: 14)
            .path(in: full).boundingRect
        let under = NotchReveal(progress: -0.4, cutout: cutout, topRadius: 10, bottomRadius: 14)
            .path(in: full).boundingRect

        XCTAssertEqual(over.width, full.width, accuracy: 0.001)
        XCTAssertEqual(under.width, cutout.width, accuracy: 0.001)
    }
}
