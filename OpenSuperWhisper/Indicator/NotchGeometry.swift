import CoreGraphics
import SwiftUI

/// Every size the bubble uses on a Mac that actually has a notch, decided once per presentation.
///
/// It exists because that geometry used to be a dozen ternaries scattered through the view, each
/// reading a state that changes while the bubble is on screen. The width came out differently in
/// every one of them, so showing a caption made the bubble *narrower* while it grew taller, and
/// the entrance animation was armed from whichever state happened to be current at that instant.
///
/// Here there is one width, computed before the view is built and never recomputed. What the
/// bubble is showing decides only its height, and therefore only whether anything hangs below the
/// hardware.
///
/// `nil` on a screen without a cutout, which keeps the drawn-on pill those Macs get entirely out
/// of this: it is a look with preferences, not a fitting with measurements, and conflating the
/// two is what put the bubble behind the notch in the first place.
struct NotchGeometry: Equatable {

    /// The cutout, exactly as measured.
    let cutout: CGSize

    /// Room reserved on each flank. Equal by construction: the window is centred and so is the
    /// cutout, so an uneven pair would slide the hole off the hardware by half the difference.
    let sideWidth: CGFloat

    /// The one width, in every state.
    let width: CGFloat

    let topRadius: CGFloat
    let bottomRadius: CGFloat

    /// The band level with the hardware. A floor *and* a ceiling: content that grew past it would
    /// spill out from under the notch, and content that stopped short would leave a black lip.
    var bandHeight: CGFloat { cutout.height }

    // MARK: - Measuring the flanks

    /// Between the flank's contents and the cutout.
    static let innerGutter: CGFloat = 12
    /// Between the flank's contents and the outer edge of the pill.
    static let outerGutter: CGFloat = 14
    /// The gap the bubble puts between two elements on the same side.
    static let elementSpacing: CGFloat = 10

    /// Drawn widths, not guesses. Each one matches what `IndicatorElementView` puts on screen,
    /// because the flank is a fixed frame: reserve less than an element draws and it is clipped,
    /// reserve more and the hole drifts off the hardware.
    static func elementWidth(_ element: IndicatorElement, textScale: CGFloat) -> CGFloat {
        switch element {
        case .dot: return 16 * textScale
        case .waveform: return InputLevelMeter.width
        // "Transcribing…" is the longest of the three words the label can hold, and it is set
        // on one line whatever happens, so this is the width to keep clear.
        case .label: return 96 * textScale
        case .stopButton, .cancelButton: return 24
        }
    }

    static func rowWidth(_ elements: [IndicatorElement], textScale: CGFloat) -> CGFloat {
        guard !elements.isEmpty else { return 0 }
        let content = elements.reduce(0) { $0 + elementWidth($1, textScale: textScale) }
        return content + CGFloat(elements.count - 1) * elementSpacing
    }

    /// The widest either flank ever needs during one presentation.
    ///
    /// Deliberately the maximum over recording *and* transcribing: a layout with neither meter
    /// nor label borrows the meter to carry the spinner, and sizing to the current state would
    /// make the bubble jump wider the moment the user stops talking.
    static func flankWidth(for layout: IndicatorLayout, textScale: CGFloat) -> CGFloat {
        let leading = max(rowWidth(layout.leading, textScale: textScale),
                          rowWidth(layout.decodingLeading, textScale: textScale))
        let trailing = rowWidth(layout.trailing, textScale: textScale)
        return max(leading, trailing) + innerGutter + outerGutter
    }

    // MARK: - Building it

    /// - Parameter topRadius: `NotchShape` pulls its top corners inward by this much, so a pill
    ///   merely as wide as the cutout draws black *narrower* than the hardware and the notch
    ///   shows past both edges. The floor below pays for both wings.
    init?(cutout: CGSize?, sideWidth: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat) {
        guard let cutout, cutout.width > 0, cutout.height > 0 else { return nil }
        self.cutout = cutout
        self.sideWidth = max(0, sideWidth)
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.width = max(self.sideWidth * 2 + cutout.width, cutout.width + 2 * topRadius)
    }

    /// The one place the width is worked out, called by the view that draws the bubble and by the
    /// manager that sizes the window for it. Two callers, one answer: a window seeded from a
    /// different number than the view lays out in is what made the bubble visibly jump on the way
    /// in.
    static func measure(cutout: CGSize?, layout: IndicatorLayout, textScale: CGFloat,
                        topRadius: CGFloat, bottomRadius: CGFloat) -> NotchGeometry? {
        NotchGeometry(cutout: cutout,
                      sideWidth: flankWidth(for: layout, textScale: textScale),
                      topRadius: topRadius,
                      bottomRadius: bottomRadius)
    }
}
