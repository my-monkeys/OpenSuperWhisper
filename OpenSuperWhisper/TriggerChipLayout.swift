import SwiftUI

/// The bordered cap the chip style draws each shortcut in, terracotta while it is capturing.
struct TriggerChipFrame: ViewModifier {
    let armed: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(armed ? STheme.accentSoft : STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(armed ? STheme.accent : STheme.border, lineWidth: 1))
            .fixedSize()
    }
}

/// Lays chips out in lines, right-aligned, wrapping when the width offered runs out, so a long
/// list of shortcuts grows downwards instead of pushing the row's label off the side.
struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Never narrower than this (or the whole row of chips, if shorter): offered nothing, as an
    /// HStack does when it measures, it would otherwise stack every chip on its own line.
    var minimumWidth: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let oneLine = arrange(subviews, width: .infinity).first?.width ?? 0
        let lines = arrange(subviews, width: max(proposal.width ?? .infinity, min(oneLine, minimumWidth)))
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.maxX - line.width
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
