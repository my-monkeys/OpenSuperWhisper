import SwiftUI
import OpenSuperWhisperCore

/// The recording bubble: a live preview on top of the card, where it appears, how big it is, and
/// with Advanced on, what it contains and the waveform and notch details.
struct AppearanceBubbleGroup: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var layout = IndicatorLayoutModel()
    @ObservedObject private var themeController = ThemeController.shared
    @ObservedObject private var notch = NotchTuning.shared

    private static let notchWidthRange: ClosedRange<Double> = 160...400

    private var isGlass: Bool { themeController.theme.resolved == .liquidGlass }

    var body: some View {
        SettingsGroup("Recording bubble", subtitle: "Live preview") {
            IndicatorBubblePreview(model: layout, position: viewModel.indicatorPosition)
            SettingRow("Position", hint: IndicatorPositionOptions.hint) {
                SPicker(selection: $viewModel.indicatorPosition, options: IndicatorPositionOptions.all)
            }
            SettingRow("Bubble size",
                       hint: isGlass
                           ? "Size of the Liquid Glass bubble. Applies from the next recording."
                           : "Only for the Liquid Glass bubble.") {
                SSlider(value: $themeController.glassBubbleSize.rubricSnapped(to: 0.05),
                        range: ThemeController.glassBubbleSizeRange,
                        valueLabel: "\(Int((themeController.glassBubbleSize * 100).rounded())) %")
                    .disabled(!isGlass)
            }
            SettingRow("Order and display",
                       hint: "Drag to reorder. The buttons always stay on the right.",
                       advanced: true, stacked: true) {
                IndicatorElementList(model: layout) { upcomingRows }
            }
            SettingRow("Waveform style", advanced: true, soon: true) {
                SSegmented(selection: .constant(0),
                           options: [(0, "Bars"), (1, "Spectrum"), (2, "Dots")])
            }
            if layout.layout.contains(.waveform) {
                SettingRow("Waveform height", advanced: true) {
                    IndicatorWaveformHeightSlider(model: layout)
                }
            }
            // The drawn notch is what every Mac without one already gets in Notch position; a
            // switch to turn it off does not exist yet.
            SettingRow("Simulated notch on screens without one", advanced: true, soon: true) {
                SSwitch(isOn: .constant(true))
            }
            SettingRow("Notch opening width",
                       hint: "Width of the drawn notch on screens without one.",
                       badge: notch.width == 220 ? nil : ("Customized", .custom),
                       advanced: true) {
                SSlider(value: $notch.width.rubricSnapped(to: 10), range: Self.notchWidthRange,
                        valueLabel: "\(Int(notch.width)) pt")
            }
        }
    }

    /// Elements the design adds to the bubble, listed where they will go but not built yet.
    @ViewBuilder private var upcomingRows: some View {
        upcomingRow(symbol: "pencil.tip", title: "Active style", subtitle: "Pro, Personal… before you speak")
        upcomingRow(symbol: "text.alignleft", title: "Live text", subtitle: "The last words recognised")
        upcomingRow(symbol: "quote.opening", title: "Recognised snippet", subtitle: "The snippet's name before it is inserted")
    }

    private func upcomingRow(symbol: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        IndicatorListRow(symbol: symbol, title: title, subtitle: subtitle, active: false, handle: .inert) {
            HStack(spacing: 10) {
                SoonBadge()
                SSwitch(isOn: .constant(false))
                    .controlSize(.small)
                    .disabled(true)
            }
        }
    }
}
