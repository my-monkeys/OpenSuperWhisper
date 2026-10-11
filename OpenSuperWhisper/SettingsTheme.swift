import SwiftUI
import AppKit

/// Design tokens of the app ("Redesign App v3"): a warm cream surface in light mode, warm
/// charcoal brown in dark mode, one terracotta accent. Every token adapts to the appearance the
/// window resolves, so the `appAppearance` preference (System / Light / Dark) and the system
/// setting both reach every view that reads them.
///
/// The older names (`windowBg`, `controlBg`, `hint`…) stay, pointed at the new palette, so the
/// views that predate the redesign take it on without a rewrite.
enum STheme {
    private static func dyn(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    // MARK: Accent

    /// Terracotta. Darker in light mode so text in it keeps 4.5:1 on cream.
    static let accent = dyn(dark: hex(0xE0754A), light: hex(0xA94327))
    /// Selected navigation row, chips, the halo around the record button.
    static let accentSoft = dyn(dark: hex(0xE0754A, 0.20), light: hex(0xFAE0CC))
    /// A row or card that is highlighted rather than selected.
    static let accentTint = dyn(dark: hex(0xE0754A, 0.10), light: hex(0xFBF3EC))
    /// Text and glyphs drawn on an accent fill.
    static let onAccent = dyn(dark: hex(0x2A1A12), light: hex(0xFFF8F2))
    static let accentPressed = dyn(dark: hex(0xC9653E), light: hex(0x84371F))

    // MARK: Surfaces

    static let windowBg  = dyn(dark: hex(0x221E1B), light: hex(0xFFFDF9))
    static let sidebarBg = dyn(dark: hex(0x1C1917), light: hex(0xF6F2ED))
    /// A settings group, a dialog, the agent panel.
    static let cardBg    = dyn(dark: hex(0x2A2522), light: hex(0xFFFDF9))
    /// Filled tiles (the three summary cards, code, quiet buttons).
    static let fill      = dyn(dark: hex(0x3A332E), light: hex(0xF4EEE7))
    /// Rows revealed by the Advanced switch.
    static let advancedBg = dyn(dark: hex(0x2F2925), light: hex(0xFBF6F0))
    static let noticeBg  = dyn(dark: hex(0xE0754A, 0.12), light: hex(0xFBEFE4))
    static let inputBg   = dyn(dark: hex(0x1F1B19), light: hex(0xFFFDF9))
    static let controlBg = dyn(dark: hex(0x342D29), light: hex(0xFFFDF9))
    static let border    = dyn(dark: hex(0x3D3530), light: hex(0xE7DFD6))
    static let controlBorder = dyn(dark: hex(0x4A403A), light: hex(0xE0D6CB))
    /// Off state of a switch, empty part of a slider track.
    static let track     = dyn(dark: hex(0x4A403A), light: hex(0xD9CFC4))
    static let scrim     = dyn(dark: hex(0x000000, 0.45), light: hex(0x3A2A20, 0.28))

    // MARK: Text

    static let textBright = dyn(dark: hex(0xF3EBE3), light: hex(0x332C28))
    static let text      = dyn(dark: hex(0xE6DCD3), light: hex(0x3A322D))
    static let textSecondary = dyn(dark: hex(0xD6CBC2), light: hex(0x5A4F48))
    /// Help text under a label. 4.5:1 on the window in both modes.
    static let hint      = dyn(dark: hex(0xB9ACA2), light: hex(0x71645C))
    static let faint     = dyn(dark: hex(0x8A7D74), light: hex(0xB3A69C))
    static let sectionTitle = textBright
    static let sidebarItem = textSecondary

    // MARK: Status

    static let warn      = dyn(dark: hex(0xF0A35E), light: hex(0xB4561F))
    static let warnBg    = dyn(dark: hex(0xF0A35E, 0.10), light: hex(0xFBEFE4))
    static let warnBorder = dyn(dark: hex(0xF0A35E, 0.30), light: hex(0xF1D3BC))
    static let ok        = dyn(dark: hex(0x8FD3A5), light: hex(0x315E42))
    static let okBg      = dyn(dark: hex(0x2E4A39), light: hex(0xDCEADE))
    static let okBorder  = dyn(dark: hex(0x3C5E49), light: hex(0xC4DCCB))
    static let readyDot  = dyn(dark: hex(0x6FC08F), light: hex(0x31634C))
    static let danger    = dyn(dark: hex(0xF08A7A), light: hex(0xA94327))
    static let customText = dyn(dark: hex(0xD7A6E3), light: hex(0x7A3F8A))
    static let customBg  = dyn(dark: hex(0x46304D), light: hex(0xEFE0F3))
}

// MARK: - Reusable pieces

/// Uppercase section header with a trailing hairline, per the design.
struct SSectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(size: 11, weight: .bold)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(STheme.sectionTitle)
            Rectangle().fill(STheme.border).frame(height: 1)
        }
    }
}

/// One settings row: title (+ optional hint under it) on the left, control on the right.
struct SRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var hintColor: Color = STheme.hint
    var indented = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.text)
                if let hint {
                    Text(hint)
                        .scaledFont(size: 11)
                        .foregroundColor(hintColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, indented ? 16 : 0)
        .frame(minHeight: 26)
    }
}

/// Small bordered ALL-CAPS tag ("PARAKEET ONLY", "ADVANCED", …).
struct STag: View {
    let label: LocalizedStringKey
    init(_ label: LocalizedStringKey) { self.label = label }
    var body: some View {
        Text(label)
            .scaledFont(size: 9.5, weight: .bold)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundColor(STheme.hint)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(STheme.controlBorder, lineWidth: 1))
    }
}

/// Amber callout for permission warnings and destructive notices.
struct SWarnBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .scaledFont(size: 11.5)
            .foregroundColor(STheme.warn)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(STheme.warnBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.warnBorder, lineWidth: 1))
    }
}

/// Copper-tinted switch, sized like the design's compact toggles.
struct SToggle: View {
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(SwitchToggleStyle(tint: STheme.accent))
            .labelsHidden()
            .controlSize(.small)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
    }
}

/// A settings pane: consistent title header + scrollable sectioned body.
struct SPane<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let subtitle {
                    Text(subtitle).scaledFont(size: 11).foregroundColor(STheme.hint)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
            ScrollView {
                SPaneStack { content() }
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .background(STheme.windowBg)
    }
}

/// A leading-aligned vertical stack that lays every row out at the width it is offered.
///
/// A `VStack` takes the width of its widest row. So one row that could not shrink laid every
/// other row out as wide as itself, and the scroll view followed: in #138 every toggle in the
/// Output pane ended up past the window's edge, not just the control that was too wide. Here
/// only that row runs over, and the scroll view clips it. Heights are left open, as a VStack
/// under a scroll view leaves them, so a row sizes its own contents exactly as it did before.
struct SPaneStack: Layout {
    var spacing: CGFloat = 16

    #if DEBUG
    /// Every row laid out wider than its pane since the last reset, as (row, pane) widths. Read
    /// by SettingsLayoutTests: a row of SwiftUI-drawn text has no view of its own to measure.
    nonisolated(unsafe) static var overflows: [(row: CGFloat, pane: CGFloat)] = []
    #endif

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let rows = ProposedViewSize(width: width, height: nil)
        let height = subviews.map { $0.sizeThatFits(rows).height }.reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(rows)
            #if DEBUG
            if size.width > bounds.width + 0.5 { Self.overflows.append((size.width, bounds.width)) }
            #endif
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: rows)
            y += size.height + spacing
        }
    }
}

/// Themed multiline editor (regex, prompts, per-app instructions). Shared by the
/// panes that let the user type free-form text; `SettingsView.sEditor` wraps it.
struct SEditor: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .scaledFont(size: 11.5, design: .monospaced)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.controlBorder, lineWidth: 1))
    }
}

/// A titled group of rows with the hairline header.
struct SSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SSectionHeader(title)
            content()
        }
    }
}
