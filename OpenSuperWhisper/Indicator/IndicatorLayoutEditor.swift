import LiquidGlass
import SwiftUI
import UniformTypeIdentifiers

/// Composes the recording bubble: where it appears, what it contains, in what order, and how
/// tightly it is packed.
///
/// One screen with a live preview, because the previous arrangement (independent switches for
/// the stop button, the cancel button and the meter, plus a position picker elsewhere) could
/// produce layouts nobody had ever seen. Every change here is visible immediately, in the real
/// shape, drawn by the same views the bubble uses.
struct IndicatorLayoutEditor: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var spectrum = SpectrumAnalyzer.shared
    /// Observed so the preview follows the Appearance setting (and the bubble size) live.
    @ObservedObject private var themeController = ThemeController.shared

    @State private var layout: IndicatorLayout = .default
    /// Animates the preview's bars when nothing is recording, so the waveform reads as a
    /// waveform instead of a flat line.
    @State private var demoPhase: Double = 0
    @State private var dragging: IndicatorElement?

    private let demoTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            positionRow
            preview
            elementList
            geometryControls
        }
        .onAppear { layout = IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout) }
        .onReceive(demoTimer) { _ in demoPhase += 0.12 }
    }

    // MARK: - Position

    private var positionRow: some View {
        SRow(title: "Position",
             hint: "Where the bubble appears while recording. Drag the bubble itself to put it somewhere of your own, which also switches this to \"Where you drop it\". That one mode lets the bubble take clicks, so it stops being invisible to the app underneath.") {
            Picker("", selection: $viewModel.indicatorPosition) {
                Text("Near cursor").tag("cursor")
                Text("Notch").tag("notch")
                Text("Top").tag("top")
                Text("Center").tag("center")
                Text("Bottom").tag("bottom")
                Text("Where you drop it").tag("custom")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Preview

    private var isNotch: Bool { viewModel.indicatorPosition == "notch" }

    /// The bubble renders as Liquid Glass: the theme resolves to it and the position is not the
    /// notch (which keeps its own opaque silhouette), exactly the condition the real bubble uses.
    private var isGlass: Bool { themeController.theme.resolved == .liquidGlass && !isNotch }

    /// Real levels while a recording is running, a gentle idle animation otherwise.
    private var previewBands: [Float] {
        let live = spectrum.bands
        if live.contains(where: { $0 > 0.01 }) { return live }
        return (0..<SpectrumBands.count).map { index in
            let wave = sin(demoPhase * 1.6 + Double(index) * 0.8)
            return Float(0.18 + 0.32 * (wave + 1) / 2)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(STheme.hint)
            ZStack {
                if isGlass {
                    // Glass takes its look from what is behind it; over the flat settings panel
                    // it would read as a plain grey pill, so it sits on a muted desktop stand-in.
                    RoundedRectangle(cornerRadius: 10).fill(Self.glassBackdrop)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(STheme.inputBg)
                }
                if isGlass, #available(macOS 26.0, *) {
                    glassPreviewBubble
                } else {
                    previewBubble
                }
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
        }
    }

    private var previewBubble: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(layout.leading) { element in
                IndicatorElementView(element: element, bands: previewBands,
                                     meterHeight: layout.waveformHeight,
                                     isBlinking: true, queued: 0, isInteractive: false)
            }
            if !layout.trailing.isEmpty {
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach(layout.trailing) { element in
                        IndicatorElementView(element: element, bands: previewBands,
                                             meterHeight: layout.waveformHeight,
                                             isBlinking: true, queued: 0, isInteractive: false)
                    }
                }
            }
        }
        .fixedSize(horizontal: !isNotch, vertical: false)
        .padding(.horizontal, isNotch ? 22 : 16)
        .padding(.vertical, isNotch ? 10 : 7)
        .frame(minHeight: isNotch ? 42 : 36)
        .frame(minWidth: isNotch ? nil : 76)
        .frame(width: isNotch ? previewWidth : nil, alignment: isNotch ? .center : .leading)
        .background {
            if isNotch {
                NotchShape(topRadius: 8, bottomRadius: 14).fill(.black)
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.82))
            }
        }
        .colorScheme(.dark)
        .animation(.easeOut(duration: 0.15), value: layout)
    }

    private static let glassBackdrop = LinearGradient(
        colors: [Color(red: 0.16, green: 0.18, blue: 0.34),
                 Color(red: 0.32, green: 0.18, blue: 0.38),
                 Color(red: 0.12, green: 0.28, blue: 0.32)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The real Liquid Glass bubble, from the same component and inputs the indicator uses.
    @available(macOS 26.0, *)
    private var glassPreviewBubble: some View {
        RecordingBubble(showDot: layout.contains(.dot),
                        center: layout.glassCenter,
                        labelText: "Recording…",
                        bands: previewBands,
                        blinking: true,
                        waveformHeight: layout.waveformHeight,
                        size: CGFloat(themeController.glassBubbleSize),
                        glass: .regular,
                        onStop: layout.contains(.stopButton) ? {} : nil,
                        onCancel: layout.contains(.cancelButton) ? {} : nil)
            .fixedSize()
            .colorScheme(.dark)
            .animation(.easeOut(duration: 0.15), value: layout)
    }

    /// Only the notch is fixed-width; the pill sizes itself, exactly as the real bubble does.
    private var previewWidth: CGFloat {
        220 + CGFloat(layout.trailing.count) * 32
    }

    // MARK: - Elements

    private var elementList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Elements")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(STheme.hint)
            Text("Drag the handle to reorder, including elements that are switched off. Buttons always sit at the trailing edge, so they have no handle.")
                .scaledFont(size: 10.5)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(layout.order) { element in
                    if isPinned(element) {
                        row(for: element)
                    } else {
                        row(for: element)
                            .opacity(dragging == element ? 0.4 : 1)
                            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                                target: element, layout: $layout,
                                dragging: $dragging, onChange: persist))
                    }
                }
            }
        }
    }

    /// Elements whose place is fixed, so they get no drag handle: the buttons, which always sit
    /// at the trailing edge.
    private func isPinned(_ element: IndicatorElement) -> Bool {
        element.isTrailingControl
    }

    private func row(for element: IndicatorElement) -> some View {
        let visible = layout.isVisible(element)
        return HStack(spacing: 10) {
            // Buttons have no handle: they always render at the trailing edge, so moving them
            // in this list would change nothing on the bubble and only look broken.
            // Only the handle starts a drag on the others: a draggable row swallowed the
            // toggle's click.
            if isPinned(element) {
                Color.clear.frame(width: 16, height: 20)
            } else {
                Image(systemName: "line.3.horizontal")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
                    .onDrag {
                        dragging = element
                        return NSItemProvider(object: element.rawValue as NSString)
                    }
                    .pointerCursorOnHover()
            }
            Image(systemName: element.symbol)
                .scaledFont(size: 12)
                .foregroundColor(visible ? STheme.accent : STheme.hint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(element.title)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(visible ? STheme.textBright : STheme.hint)
                Text(element.subtitle)
                    .scaledFont(size: 10.5)
                    .foregroundColor(STheme.hint)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { visible },
                set: { layout.setVisible($0, for: element); persist() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
    }

    // MARK: - Geometry

    @ViewBuilder private var geometryControls: some View {
        if layout.contains(.waveform) {
            SRow(title: "Waveform height") {
                HStack(spacing: 10) {
                    Slider(value: $layout.waveformHeight, in: 10...44,
                           onEditingChanged: { editing in if !editing { persist() } })
                        .controlSize(.small)
                        .frame(width: 150)
                        .tint(STheme.accent)
                    Text("\(Int(layout.waveformHeight))pt")
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundColor(STheme.hint)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private func persist() {
        AppPreferences.shared.indicatorLayout = layout.json
    }
}

/// Moves the dragged element to the position of the row it is dropped on.
private struct ReorderDropDelegate: DropDelegate {
    let target: IndicatorElement
    @Binding var layout: IndicatorLayout
    @Binding var dragging: IndicatorElement?
    let onChange: () -> Void

    /// Reorder as the pointer passes over a row, so the list rearranges under the drag
    /// instead of only committing on release.
    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != target else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            layout.move(dragged, before: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onChange()
        return true
    }
}
