import SwiftUI

// Small pieces the Text & AI groups share: the multiline editor for prompts and patterns, and
// rows without a title (status lines, footnotes) that still sit in a `SettingsGroup` card like
// the `SettingRow`s around them.

/// A multiline text area in the redesign's input style, with a placeholder while empty.
struct TextAIEditor: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey? = nil
    var monospaced = false
    var height: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scaledFont(size: 13, design: monospaced ? .monospaced : .default)
                .foregroundColor(STheme.textBright)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 6).padding(.vertical, 7)
            if text.isEmpty, let placeholder {
                Text(placeholder)
                    .scaledFont(size: 13, design: monospaced ? .monospaced : .default)
                    .foregroundColor(STheme.faint)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }
}

/// A row with no title of its own: a status line or an explanation under the row it belongs to.
/// Same padding, hairline and advanced tint as `SettingRow`, so it reads as part of the card.
struct TextAILine<Content: View>: View {
    var advanced = false
    var indented = false
    @ViewBuilder var content: () -> Content
    @Environment(\.showsAdvanced) private var showsAdvanced

    var body: some View {
        if !advanced || showsAdvanced {
            HStack(spacing: 10) {
                content()
            }
            .padding(.leading, indented ? 34 : 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(advanced ? STheme.advancedBg : Color.clear)
            .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
    }
}

/// Help text set inside a `TextAILine`.
struct TextAIFootnote: View {
    let text: LocalizedStringKey
    var color: Color = STheme.hint

    init(_ text: LocalizedStringKey, color: Color = STheme.hint) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .scaledFont(size: 13)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A green capsule for a state that is already good ("Connected, model ready").
struct TextAIOKPill: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(STheme.ok)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(STheme.okBg))
            .overlay(Capsule().stroke(STheme.okBorder, lineWidth: 1))
            .fixedSize()
    }
}

extension Binding where Value == Double {
    /// Rounds what a slider writes to `step`. Passing the step to `Slider` itself draws a tick
    /// mark per step under the track, a dotted ruler the design does not have.
    func rubricSnapped(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = ($0 / step).rounded() * step })
    }
}
