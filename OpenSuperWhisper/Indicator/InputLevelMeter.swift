import SwiftUI

/// Five bars showing mic input while recording, so it is obvious that sound is arriving
/// before the user has spoken a whole sentence into a muted or wrong device (#47).
///
/// The frame is deliberately fixed. The indicator window is resized by hand whenever its
/// content changes size (`IndicatorWindowManager.resizeToContent`), so a meter that grew
/// with the level would resize the window at 20 Hz. Only the fill inside each bar moves.
struct InputLevelMeter: View {
    let level: Float

    private static let barCount = 5
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2.5
    private static let height: CGFloat = 13

    private var width: CGFloat {
        CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let fill = AudioLevel.barFill(index: index, count: Self.barCount, level: level)
                // Shortest bar stays visible at rest, so the meter reads as "no sound"
                // rather than as a missing element.
                let barHeight = Self.height * (0.25 + 0.75 * CGFloat(index + 1) / CGFloat(Self.barCount))
                Capsule()
                    .fill(Color.secondary.opacity(0.22 + 0.68 * Double(fill)))
                    .frame(width: Self.barWidth, height: barHeight)
            }
        }
        .frame(width: width, height: Self.height, alignment: .bottom)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}
