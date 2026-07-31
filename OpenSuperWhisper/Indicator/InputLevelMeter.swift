import SwiftUI

/// Seven bands of the mic spectrum, so the bubble shows the shape of what it is hearing
/// rather than one volume repeated seven times (#47). Vowels push the low bands, sibilants
/// the high ones, and a muted mic stays flat.
///
/// The frame is deliberately fixed for a given height. The indicator window is resized by
/// hand whenever its content changes size (`IndicatorWindowManager.resizeToContent`), so bars
/// that changed the view's footprint would resize the window on every audio frame. Only the
/// fill height inside each fixed slot moves.
struct InputLevelMeter: View {
    let bands: [Float]
    /// Set by the caller from the layout: the notch and the pill have more vertical room
    /// than the compact bubble, and taller bars read better there.
    var height: CGFloat = 16

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2.5
    /// Enough to stay visible while silent, so the meter reads as "quiet" and not "missing".
    private static let restHeight: CGFloat = 2.5

    /// Fixed, and needed by the bubble's width calculation so adding the meter can't push
    /// the "Recording…" label onto a second line.
    static let width: CGFloat = {
        let count = CGFloat(SpectrumBands.count)
        return count * barWidth + (count - 1) * barSpacing
    }()

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<SpectrumBands.count, id: \.self) { index in
                let level = CGFloat(index < bands.count ? bands[index] : 0)
                Capsule()
                    .fill(Color.secondary.opacity(0.3 + 0.6 * Double(level)))
                    .frame(width: Self.barWidth,
                           height: Self.restHeight + (height - Self.restHeight) * level)
            }
        }
        .frame(width: Self.width, height: height)
        .animation(.linear(duration: 0.06), value: bands)
        .accessibilityHidden(true)
    }
}

/// Where the spectrum meter goes on the recording bubble.
enum IndicatorMeterMode: String, CaseIterable {
    /// No meter; the blinking dot alone marks recording.
    case off
    /// The meter takes the dot's place. Keeps the bubble narrow, which matters at the
    /// compact width where a meter beside the label wraps "Recording…" onto two lines.
    case replacesDot
    /// Dot and meter both, the meter after the label.
    case besideLabel

    static func from(_ raw: String) -> IndicatorMeterMode {
        IndicatorMeterMode(rawValue: raw) ?? .replacesDot
    }

    /// Width this mode adds to the bubble compared with showing the dot alone.
    var extraBubbleWidth: CGFloat {
        switch self {
        case .off: return 0
        case .replacesDot: return max(0, InputLevelMeter.width - 16)
        case .besideLabel: return InputLevelMeter.width + 10
        }
    }
}
