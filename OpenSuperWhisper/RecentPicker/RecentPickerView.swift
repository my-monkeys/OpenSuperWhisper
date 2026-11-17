import OpenSuperWhisperCore
import SwiftUI

/// What the panel shows. The controller owns it and changes `highlighted` from the keyboard.
@MainActor
final class RecentPickerModel: ObservableObject {
    @Published var rows: [RecentPicker.Row]
    /// 0 based index into `rows`.
    @Published var highlighted = 0

    init(rows: [RecentPicker.Row] = []) { self.rows = rows }
}

/// The panel's content with the text size setting applied, like `AgentPanelRoot`.
struct RecentPickerRoot: View {
    @ObservedObject var model: RecentPickerModel
    let onPick: (RecentPicker.Row) -> Void
    @AppStorage("textScale", store: DefaultsStore.current) private var textScale: Double = TextScale.default

    var body: some View {
        RecentPickerView(model: model, onPick: onPick).environment(\.appTextScale, textScale)
    }
}

struct RecentPickerView: View {
    @ObservedObject var model: RecentPickerModel
    let onPick: (RecentPicker.Row) -> Void

    static let width: CGFloat = 420
    /// Transparent margin inside the borderless panel, for the card's shadow.
    static let shadowRoom: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .scaledFont(size: 12, weight: .semibold)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundColor(STheme.hint)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            if model.rows.isEmpty {
                Text("No dictations yet")
                    .scaledFont(size: 13.5)
                    .foregroundColor(STheme.hint)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isHighlighted: index == model.highlighted)
                    }
                }
                .padding(.horizontal, 6)
            }
            Text("1-9 insert · ↑↓ ⏎ · esc close")
                .scaledFont(size: 11.5)
                .foregroundColor(STheme.faint)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(STheme.cardBg)
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(STheme.border, lineWidth: 1))
        .padding(Self.shadowRoom)
    }

    private func rowView(_ row: RecentPicker.Row, isHighlighted: Bool) -> some View {
        Button { onPick(row) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(row.number)")
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundColor(isHighlighted ? STheme.accent : STheme.hint)
                    .frame(width: 14, alignment: .leading)
                Text(verbatim: row.preview)
                    .scaledFont(size: 13.5)
                    .foregroundColor(STheme.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: row.age)
                    .scaledFont(size: 11.5)
                    .foregroundColor(STheme.faint)
                    .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHighlighted ? STheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .onHover { inside in
            if inside, let index = model.rows.firstIndex(of: row) { model.highlighted = index }
        }
    }
}
