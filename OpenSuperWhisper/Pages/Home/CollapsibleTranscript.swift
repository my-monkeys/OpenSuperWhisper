import SwiftUI

/// A transcript in the feed: long ones fold to three lines with Show more / Show less, and the
/// words matching the search are highlighted.
struct CollapsibleTranscript: View {
    let text: String
    let searchQuery: String
    @Binding var isExpanded: Bool

    @State private var highlighted: AttributedString?
    @State private var computeTask: Task<Void, Never>?

    /// Same threshold as before the redesign: under it the text is never folded.
    private static let foldThreshold = 150

    private var isLong: Bool { text.count > Self.foldThreshold }

    private var styledText: Text {
        if !searchQuery.isEmpty, let highlighted { return Text(highlighted) }
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded && isLong {
                ScrollView {
                    transcript
                }
                .frame(maxHeight: 240)
            } else {
                transcript
                    .lineLimit(isLong ? 3 : nil)
            }
            if isLong {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(STheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear(perform: computeHighlighting)
        .onChange(of: searchQuery) { _, _ in computeHighlighting() }
        .onChange(of: text) { _, _ in computeHighlighting() }
        .onDisappear { computeTask?.cancel() }
    }

    private var transcript: some View {
        styledText
            .scaledFont(size: 15)
            .lineSpacing(3)
            .foregroundColor(STheme.textBright)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func computeHighlighting() {
        computeTask?.cancel()
        guard !searchQuery.isEmpty else {
            highlighted = nil
            return
        }
        let text = text
        let query = searchQuery
        let background = STheme.accentSoft
        computeTask = Task.detached(priority: .userInitiated) {
            var attributed = AttributedString(text)
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var start = text.startIndex
            while let range = text.range(of: query, options: options, range: start..<text.endIndex) {
                guard !Task.isCancelled else { return }
                if let attributedRange = Range(range, in: attributed) {
                    attributed[attributedRange].backgroundColor = background
                    attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                }
                start = range.upperBound
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { highlighted = attributed }
        }
    }
}

/// The sweep over a transcript being regenerated.
struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .fill(STheme.fill.opacity(0.5))
                .overlay(
                    LinearGradient(colors: [.clear, STheme.windowBg.opacity(0.7), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .offset(x: -geometry.size.width + phase * geometry.size.width * 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}
