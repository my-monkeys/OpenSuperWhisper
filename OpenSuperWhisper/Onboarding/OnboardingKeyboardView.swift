import SwiftUI

private struct KeyCap: View {
    let label: String
    let w: CGFloat
    let h: CGFloat
    let highlighted: Bool
    
    var body: some View {
        Text(label)
            .scaledFont(size: w > 20 ? 9 : 7, weight: .medium)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? STheme.accent : STheme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(highlighted ? STheme.accent : STheme.border, lineWidth: 1)
            )
            .foregroundColor(highlighted ? STheme.onAccent : STheme.hint)
    }
}

/// A Mac keyboard drawn in the user's own layout, with the keys of the chosen shortcut lit.
struct OnboardingKeyboardView: View {
    let selectedShortcut: OnboardingShortcutOption
    let layoutInfo: KeyboardLayoutInfo
    var width: CGFloat = 480
    
    private let gap: CGFloat = 2
    private let pad: CGFloat = 6
    private let refUnits: CGFloat = 14.5
    private let refGaps: CGFloat = 13
    
    private static let row0Keycodes: [UInt16] = [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    private static let row1Keycodes: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]
    private static let row2Keycodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]
    private static let row3Keycodes: [UInt16] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]
    
    private func isHighlighted(_ id: String) -> Bool {
        switch selectedShortcut {
        case .keyCombination:
            return id == "leftOption" || id == "tilde"
        case .rightOption:
            return id == "rightOption"
        }
    }
    
    private func label(_ keycode: UInt16) -> String {
        layoutInfo.labels[keycode] ?? ""
    }
    
    private func u(for width: CGFloat) -> CGFloat {
        (width - pad * 2 - gap * refGaps) / refUnits
    }
    
    private func wideKey(singleCount: Int, wideCount: Int, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let totalGaps = CGFloat(singleCount + wideCount - 1) * gap
        return (rowWidth - singleWidth - totalGaps) / CGFloat(wideCount)
    }
    
    private func spaceWidth(singleCount: Int, cmdWidth: CGFloat, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let cmds = cmdWidth * 2
        let totalGaps = CGFloat(singleCount + 3) * gap
        return rowWidth - singleWidth - cmds - totalGaps
    }
    
    var body: some View {
        GeometryReader { geo in
            let u = u(for: geo.size.width)
            let h = u
            
            let backspace = refUnits * u + refGaps * gap - 13 * u - 13 * gap
            let tab = backspace
            let caps = wideKey(singleCount: 11, wideCount: 2, u: u)
            let shift = wideKey(singleCount: 10, wideCount: 2, u: u)
            let cmd = u * 1.25
            let space = spaceWidth(singleCount: 7, cmdWidth: cmd, u: u)
            
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    KeyCap(label: label(50), w: u, h: h, highlighted: isHighlighted("tilde"))
                    ForEach(Array(Self.row0Keycodes.dropFirst()), id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⌫", w: backspace, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇥", w: tab, h: h, highlighted: false)
                    ForEach(Self.row1Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: label(42), w: u, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇪", w: caps, h: h, highlighted: false)
                    ForEach(Self.row2Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⏎", w: caps, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                    ForEach(Self.row3Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "fn", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌃", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("leftOption"))
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "", w: space, h: h, highlighted: false)
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("rightOption"))
                    KeyCap(label: "←", w: u, h: h, highlighted: false)
                    VStack(spacing: 1) {
                        KeyCap(label: "↑", w: u, h: h / 2 - 0.5, highlighted: false)
                        KeyCap(label: "↓", w: u, h: h / 2 - 0.5, highlighted: false)
                    }
                    KeyCap(label: "→", w: u, h: h, highlighted: false)
                }
            }
            .padding(pad)
        }
        .frame(width: width, height: heightForWidth(width))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(STheme.fill)
        )
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.2), value: selectedShortcut)
    }
    
    private func heightForWidth(_ width: CGFloat) -> CGFloat {
        let u = u(for: width)
        return pad * 2 + u * 5 + gap * 4
    }
}
