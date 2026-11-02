import SwiftUI

/// Draws one element of the recording bubble. Shared by the bubble itself and by the layout
/// editor's preview, so what the editor shows is the thing that will appear on screen rather
/// than an approximation of it.
struct IndicatorElementView: View {
    let element: IndicatorElement
    var bands: [Float] = []
    var meterHeight: CGFloat = 30
    var isBlinking = false
    /// Hands-free (Space-latched) recording: the dot swells, goes solid and pulses.
    var isLatched = false
    var queued = 0
    /// The editor's preview has no manager to call, so its buttons do nothing.
    var isInteractive = true

    /// Recording is over and the clip is being transcribed. Each element shows its waiting form
    /// in the same footprint, so the bubble does not resize between the two states: the meter
    /// becomes a spinner of exactly its width, the label changes its words.
    var isDecoding = false

    /// While decoding, the AI cleanup model is the one working: the label says so.
    var isCleaningUp = false

    /// The bubble is mostly graphics, so its dimensions follow the text setting too — otherwise
    /// raising it moves the one small label and nothing else.
    @Environment(\.textScaleFactor) private var scale

    var body: some View {
        switch element {
        case .dot:
            RecordingIndicator(isBlinking: isBlinking, isLatched: isLatched)
                .frame(width: 16 * scale)
        case .waveform:
            if isDecoding {
                // Scaled up to the meter's own height. A spinner left at its intrinsic 16pt sat
                // as a dot in the middle of a 30pt-tall gap, which read as something broken
                // rather than something working. The frame keeps the meter's exact footprint,
                // so only the drawing changes size, never the bubble.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .scaleEffect(spinnerScale)
                    .frame(width: InputLevelMeter.width, height: meterHeight * scale)
            } else {
                InputLevelMeter(bands: bands, height: meterHeight * scale)
            }
        case .label:
            Text(labelText)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(.secondary)
                // The bubble is a fixed width, so the label would wrap rather than widen it.
                // One line always: a two-line "Recording…" is worse than a truncated one.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .transition(.opacity)
        case .stopButton:
            // Already stopped: kept in place, greyed, so the bubble does not reflow when the
            // recording ends.
            button(symbol: "stop.circle", size: 19,
                   help: isDecoding ? "Already stopped" : "Finish recording",
                   enabled: !isDecoding) {
                IndicatorWindowManager.shared.stopRecording()
            }
        case .cancelButton:
            // Stays live through the transcription: changing your mind is exactly what happens
            // while you watch a slow model work, and until the text lands there is still
            // something to throw away.
            button(symbol: "trash", size: 16,
                   help: isDecoding ? "Throw this transcription away" : "Discard recording") {
                if isDecoding {
                    DictationPipeline.shared.discardEverything()
                } else {
                    IndicatorWindowManager.shared.stopForce()
                }
            }
        }
    }

    /// A circular `ProgressView` draws at 16pt whatever frame it is given, so matching the meter
    /// means scaling the drawing itself.
    private static let spinnerIntrinsicSize: CGFloat = 16

    /// Well short of the meter's full height on purpose. A disc filling all 30pt looks heavier
    /// than the bars beside it, which only reach the top on peaks. Settled by eye at a little
    /// over a third, which sits level with them rather than above.
    private static let spinnerHeightRatio: CGFloat = 0.38

    /// Below this it stops reading as a spinner and starts reading as a speck.
    private static let spinnerMinimumSize: CGFloat = 10

    private var spinnerScale: CGFloat {
        let target = max(Self.spinnerMinimumSize, meterHeight * scale * Self.spinnerHeightRatio)
        return target / Self.spinnerIntrinsicSize
    }

    private var labelText: String {
        if isDecoding {
            let waiting = queued - 1
            if isCleaningUp {
                return waiting > 0 ? String(localized: "Cleaning up… · \(waiting) queued") : String(localized: "Cleaning up…")
            }
            return waiting > 0 ? String(localized: "Transcribing… · \(waiting) queued") : String(localized: "Transcribing…")
        }
        return queued > 0 ? String(localized: "Recording… · \(queued) queued") : String(localized: "Recording…")
    }

    private func button(symbol: String, size: CGFloat, help: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button { if isInteractive && enabled { action() } } label: {
            Image(systemName: symbol)
                .scaledFont(size: size, weight: .regular)
                .foregroundColor(enabled ? .red : .secondary)
                .opacity(enabled ? 1 : 0.4)
                .frame(width: 24 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .help(help)
        .allowsHitTesting(isInteractive && enabled)
    }
}
