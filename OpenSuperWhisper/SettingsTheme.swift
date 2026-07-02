import SwiftUI
import AppKit

/// Design tokens for the redesigned Settings window ("Atelier" direction —
/// Settings Explorations.dc.html). Copper accent, quiet surfaces, hairline
/// sections. Adaptive: the dark values are the design's; light mode derives
/// equivalent neutrals so the window follows the system appearance.
enum STheme {
    private static func dyn(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// Copper accent — identical in both appearances.
    static let accent = Color(nsColor: hex(0xE8734A))
    static let accentSoft = dyn(dark: hex(0xE8734A, 0.13), light: hex(0xE8734A, 0.12))

    static let windowBg  = dyn(dark: hex(0x161619), light: hex(0xF6F6F8))
    static let sidebarBg = dyn(dark: hex(0x1B1B1F), light: hex(0xEEEEF1))
    static let border    = dyn(dark: hex(0x26262B), light: hex(0xE0E0E5))
    static let cardBg    = dyn(dark: hex(0x19191D), light: hex(0xFFFFFF))
    static let inputBg   = dyn(dark: hex(0x101013), light: hex(0xFFFFFF))
    static let controlBg = dyn(dark: hex(0x26262D), light: hex(0xFFFFFF))
    static let controlBorder = dyn(dark: hex(0x34343C), light: hex(0xD5D5DC))

    static let text      = dyn(dark: hex(0xD9D9E0), light: hex(0x2A2A30))
    static let textBright = dyn(dark: hex(0xE8E8EA), light: hex(0x1A1A1E))
    static let hint      = dyn(dark: hex(0x6D6D78), light: hex(0x8A8A94))
    static let sectionTitle = dyn(dark: hex(0x6D6D78), light: hex(0x9494A0))
    static let sidebarItem = dyn(dark: hex(0xB9B9C2), light: hex(0x4A4A52))

    static let warn      = Color(nsColor: hex(0xF0A35E))
    static let warnBg    = dyn(dark: hex(0xF0A35E, 0.07), light: hex(0xF0A35E, 0.12))
    static let warnBorder = dyn(dark: hex(0xF0A35E, 0.30), light: hex(0xF0A35E, 0.45))
    static let ok        = dyn(dark: hex(0x4ADE80), light: hex(0x2EA562))
    static let okBg      = dyn(dark: hex(0x3CC878, 0.14), light: hex(0x2EA562, 0.14))
}

// MARK: - Reusable pieces

/// Uppercase section header with a trailing hairline, per the design.
struct SSectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
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
                    .font(.system(size: 13))
                    .foregroundColor(STheme.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
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
            .font(.system(size: 9.5, weight: .bold))
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
            .font(.system(size: 11.5))
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
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundColor(STheme.hint)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .background(STheme.windowBg)
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
