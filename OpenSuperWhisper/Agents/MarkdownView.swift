import SwiftUI

/// Lays out an agent's Markdown reply: the blocks from `MarkdownBlock`, inline styling from
/// `AttributedString`. Sized for reading at a glance in the agent panel, not for documents.
struct MarkdownView: View {
    let markdown: String
    var fontSize: CGFloat = 14

    var body: some View {
        stack(MarkdownBlock.parse(markdown))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Type-erased because a quote lays out its blocks through here, and `view(for:)` lays out the
    /// quote: an opaque return type cannot contain itself.
    private func stack(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        })
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .scaledFont(size: fontSize + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            prose(text)
        case .bullet(let items):
            list(items) { _ in "•" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .scaledFont(size: fontSize - 1.5, design: .monospaced)
                    .foregroundColor(STheme.textBright)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.fill))
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(STheme.accent.opacity(0.6)).frame(width: 3)
                stack(blocks)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .rule:
            Rectangle().fill(STheme.border).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(Self.inline(text))
            .scaledFont(size: fontSize)
            .foregroundColor(STheme.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .scaledFont(size: fontSize, weight: .medium)
                        .monospacedDigit()
                        .foregroundColor(STheme.hint)
                        .frame(minWidth: 14, alignment: .trailing)
                    prose(item)
                }
            }
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Self.inline(column < header.count ? header[column] : ""))
                            .scaledFont(size: fontSize - 1, weight: .semibold)
                            .foregroundColor(STheme.textBright)
                    }
                }
                Rectangle().fill(STheme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(Self.inline(column < row.count ? row[column] : ""))
                                .scaledFont(size: fontSize - 1)
                                .monospacedDigit()
                                .foregroundColor(STheme.text)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.fill))
    }

    /// Inline styling, with code spans set on a light fill so identifiers stand out from prose.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].backgroundColor = STheme.fill
            styled[run.range].foregroundColor = STheme.textBright
        }
        return styled
    }
}
