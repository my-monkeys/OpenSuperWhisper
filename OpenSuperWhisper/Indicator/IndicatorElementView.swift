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

    var body: some View {
        switch element {
        case .dot:
            RecordingIndicator(isBlinking: isBlinking, isLatched: isLatched)
                .frame(width: 16)
        case .waveform:
            InputLevelMeter(bands: bands, height: meterHeight)
        case .label:
            Text(queued > 0 ? "Recording… · \(queued) queued" : "Recording…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                // The bubble is a fixed width, so the label would wrap rather than widen it.
                // One line always: a two-line "Recording…" is worse than a truncated one.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .transition(.opacity)
        case .stopButton:
            button(symbol: "stop.circle", size: 19, help: "Finish recording") {
                IndicatorWindowManager.shared.stopRecording()
            }
        case .cancelButton:
            button(symbol: "trash", size: 16, help: "Discard recording") {
                IndicatorWindowManager.shared.stopForce()
            }
        }
    }

    private func button(symbol: String, size: CGFloat, help: String,
                        action: @escaping () -> Void) -> some View {
        Button { if isInteractive { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(.red)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .help(help)
        .allowsHitTesting(isInteractive)
    }
}
