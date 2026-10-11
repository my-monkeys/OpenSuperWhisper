import LiquidGlass
import SwiftUI
import UniformTypeIdentifiers

/// The recording bubble's layout while it is being edited. One instance is shared by the preview,
/// the element list and the waveform slider, so a change in one shows in the others at once.
///
/// Saved explicitly (`persist()`), not on every change: a drag reorders the list as the pointer
/// passes over rows, and only the drop is a decision worth storing.
final class IndicatorLayoutModel: ObservableObject {
    @Published var layout: IndicatorLayout

    init() {
        layout = IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout)
    }

    func setVisible(_ visible: Bool, for element: IndicatorElement) {
        layout.setVisible(visible, for: element)
        persist()
    }

    func persist() {
        AppPreferences.shared.indicatorLayout = layout.json
    }
}

/// Composes the recording bubble: where it appears, what it contains, in what order, and how
/// tightly it is packed. The settings' Appearance rubric lays these pieces out as rows of its own;
/// this view keeps them together for the places that want the whole editor in one block.
///
/// One screen with a live preview, because the previous arrangement (independent switches for
/// the stop button, the cancel button and the meter, plus a position picker elsewhere) could
/// produce layouts nobody had ever seen. Every change here is visible immediately, in the real
/// shape, drawn by the same views the bubble uses.
struct IndicatorLayoutEditor: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var model = IndicatorLayoutModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingRow("Position", hint: IndicatorPositionOptions.hint) {
                SPicker(selection: $viewModel.indicatorPosition, options: IndicatorPositionOptions.all)
            }
            IndicatorBubblePreview(model: model, position: viewModel.indicatorPosition)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            IndicatorElementList(model: model)
            if model.layout.contains(.waveform) {
                SettingRow("Waveform height") {
                    IndicatorWaveformHeightSlider(model: model)
                }
            }
        }
    }
}

/// The bubble's positions, as the menu offers them.
enum IndicatorPositionOptions {
    static let all: [(value: String, label: LocalizedStringKey)] = [
        ("cursor", "Near cursor"),
        ("notch", "Notch"),
        ("top", "Top"),
        ("center", "Center"),
        ("bottom", "Bottom"),
        ("custom", "Where you drop it"),
    ]

    static let hint: LocalizedStringKey =
        "Drag the bubble to place it elsewhere: the position becomes “Where you drop it”."
}

// MARK: - Preview

/// The bubble as it will look, drawn by the same views the indicator uses, over a backdrop.
struct IndicatorBubblePreview: View {
    @ObservedObject var model: IndicatorLayoutModel
    let position: String
    var height: CGFloat = 120
    @ObservedObject private var spectrum = SpectrumAnalyzer.shared
    /// Observed so the preview follows the Liquid Glass switch (and the bubble size) live.
    @ObservedObject private var themeController = ThemeController.shared
    @ObservedObject private var notch = NotchTuning.shared
    /// Animates the bars when nothing is recording, so the waveform reads as a waveform instead
    /// of a flat line.
    @State private var demoPhase: Double = 0

    private let demoTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    private var layout: IndicatorLayout { model.layout }
    private var isNotch: Bool { position == "notch" }

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

    var body: some View {
        ZStack {
            // Glass takes its look from what is behind it; over the flat settings card it would
            // read as a plain grey pill, so every bubble sits on a muted desktop stand-in.
            Self.backdrop
            if isGlass, #available(macOS 26.0, *) {
                glassBubble
            } else {
                classicBubble
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onReceive(demoTimer) { _ in demoPhase += 0.12 }
    }

    private static let backdrop = LinearGradient(
        colors: [Color(red: 0.16, green: 0.18, blue: 0.34),
                 Color(red: 0.32, green: 0.18, blue: 0.38),
                 Color(red: 0.12, green: 0.28, blue: 0.32)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private func elementView(_ element: IndicatorElement) -> some View {
        IndicatorElementView(element: element, bands: previewBands,
                             meterHeight: layout.waveformHeight,
                             isBlinking: true, queued: 0, isInteractive: false)
    }

    private var classicBubble: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(layout.leading) { elementView($0) }
            if !layout.trailing.isEmpty {
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach(layout.trailing) { elementView($0) }
                }
            }
        }
        .fixedSize(horizontal: !isNotch, vertical: false)
        .padding(.horizontal, isNotch ? 22 : 16)
        .padding(.vertical, isNotch ? 10 : 7)
        .frame(minHeight: isNotch ? 42 : 36)
        .frame(minWidth: isNotch ? nil : 76)
        .frame(width: isNotch ? notchWidth : nil, alignment: isNotch ? .center : .leading)
        .background {
            if isNotch {
                NotchShape(topRadius: 8, bottomRadius: 14).fill(.black)
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.82))
            }
        }
        .frame(maxHeight: .infinity, alignment: isNotch ? .top : .center)
        .colorScheme(.dark)
        .animation(.easeOut(duration: 0.15), value: layout)
    }

    /// The real Liquid Glass bubble, from the same component and inputs the indicator uses.
    @available(macOS 26.0, *)
    private var glassBubble: some View {
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
    private var notchWidth: CGFloat {
        CGFloat(notch.width) + CGFloat(layout.trailing.count) * 32
    }
}

// MARK: - Elements

/// The bubble's elements in order, each with its switch. The handle reorders, including elements
/// that are switched off; the buttons have none because they always sit at the trailing edge.
/// `upcoming` rows (elements announced but not built) are drawn between the two.
struct IndicatorElementList<Upcoming: View>: View {
    @ObservedObject var model: IndicatorLayoutModel
    @ViewBuilder var upcoming: () -> Upcoming
    @State private var dragging: IndicatorElement?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.layout.order.filter { !$0.isTrailingControl }) { element in
                row(for: element)
                    .opacity(dragging == element ? 0.4 : 1)
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(
                        target: element, layout: $model.layout,
                        dragging: $dragging, onChange: model.persist))
            }
            upcoming()
            // Listed last because that is where they render, whatever their place in `order`.
            ForEach(model.layout.order.filter(\.isTrailingControl)) { element in
                row(for: element)
            }
        }
    }

    private func row(for element: IndicatorElement) -> some View {
        let visible = model.layout.isVisible(element)
        return IndicatorListRow(symbol: element.symbol,
                                title: LocalizedStringKey(element.title),
                                subtitle: LocalizedStringKey(element.subtitle),
                                active: visible,
                                handle: element.isTrailingControl ? .none : .drag {
                                    dragging = element
                                    return NSItemProvider(object: element.rawValue as NSString)
                                }) {
            SSwitch(isOn: Binding(get: { visible },
                                  set: { model.setVisible($0, for: element) }))
                .controlSize(.small)
        }
    }

    init(model: IndicatorLayoutModel, @ViewBuilder upcoming: @escaping () -> Upcoming) {
        self.model = model
        self.upcoming = upcoming
    }
}

extension IndicatorElementList where Upcoming == EmptyView {
    init(model: IndicatorLayoutModel) {
        self.init(model: model) { EmptyView() }
    }
}

/// One line of the element list: handle, icon, name and description, then its control.
struct IndicatorListRow<Trailing: View>: View {
    enum Handle {
        /// No handle, keeping its room so the icons stay aligned.
        case none
        /// A handle drawn faded that does nothing (an element not built yet).
        case inert
        case drag(() -> NSItemProvider)
    }

    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var active: Bool
    var handle: Handle
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            handleView
            Image(systemName: symbol)
                .scaledFont(size: 14, weight: .medium)
                .foregroundColor(active ? STheme.accent : STheme.hint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(active ? STheme.textBright : STheme.hint)
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.controlBg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }

    /// Only the handle starts a drag: a draggable row swallowed the switch's click.
    @ViewBuilder private var handleView: some View {
        let lines = Image(systemName: "line.3.horizontal")
            .scaledFont(size: 12)
            .frame(width: 16, height: 22)
        switch handle {
        case .none:
            Color.clear.frame(width: 16, height: 22)
        case .inert:
            lines.foregroundColor(STheme.faint)
        case .drag(let provider):
            lines
                .foregroundColor(STheme.hint)
                .contentShape(Rectangle())
                .onDrag(provider)
                .pointerCursorOnHover()
        }
    }
}

// MARK: - Geometry

/// The waveform's height, saved when the drag ends rather than at every step.
struct IndicatorWaveformHeightSlider: View {
    @ObservedObject var model: IndicatorLayoutModel

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $model.layout.waveformHeight, in: 10...44,
                   onEditingChanged: { editing in if !editing { model.persist() } })
                .tint(STheme.accent)
                .frame(width: 180)
            Text(verbatim: "\(Int(model.layout.waveformHeight)) pt")
                .scaledFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundColor(STheme.textSecondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
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
