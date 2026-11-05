import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// "Original ⌄" on the meta line of a dictation the cleanup changed (#168): filler words taken
/// out, or the AI rewriting it. Quiet, since with the cleanup on most rows have one.
struct FeedRowOriginalToggle: View {
    @Binding var isShown: Bool

    var body: some View {
        Button { isShown.toggle() } label: {
            HStack(spacing: 3) {
                Text("Original")
                Image(systemName: isShown ? "chevron.up" : "chevron.down")
                    .scaledFont(size: 9, weight: .semibold)
            }
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(isShown ? STheme.accent : STheme.hint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the text as the engine wrote it, before the cleanup")
        .fixedSize()
    }
}

/// What the cleanup changed, under the text the user got: the engine's words and the cleaned
/// ones in one flowing text, and a toggle for the engine's text alone. Both texts stay in the
/// history; nothing is replaced.
struct FeedRowOriginalText: View {
    let original: String
    let cleaned: String
    let cleanupModel: String?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(STheme.border).frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                OriginalComparison(original: original, cleaned: cleaned, cleanupModel: cleanupModel)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy original",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.sSecondary)
                .help("Copy this text, to paste it where the cleaned one went")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// The header, the diff and the "Show original" toggle, shared by the history row and the
/// report card (#277).
struct OriginalComparison: View {
    let original: String
    let cleaned: String
    let cleanupModel: String?
    var lineLimit: Int? = nil
    @State private var showsPlain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                title
                    .scaledFont(size: 11, weight: .bold)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(STheme.hint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { showsPlain.toggle() } label: {
                    Text(showsPlain ? "Show changes" : "Show original")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(STheme.accent)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if showsPlain {
                Text(verbatim: original)
                    .scaledFont(size: 14)
                    .lineSpacing(2)
                    .foregroundColor(STheme.textSecondary)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                TextDiffView(original: original, cleaned: cleaned)
                    .lineLimit(lineLimit)
            }
        }
    }

    private var title: Text {
        if showsPlain { return Text("Before cleanup") }
        guard let cleanupModel else { return Text("Changes made by the cleanup") }
        return Text("Cleaned up by \(cleanupModel)")
    }
}

/// The two texts in one flow: words the cleanup removed struck through in red, words it added in
/// green on a soft tint. The strike and the tint carry the meaning too, for anyone who cannot
/// tell the colours apart.
struct TextDiffView: View {
    let original: String
    let cleaned: String

    var body: some View {
        Text(attributed)
            .scaledFont(size: 14)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in TextDiff.segments(from: original, to: cleaned) {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .unchanged:
                piece.foregroundColor = STheme.textSecondary
            case .removed:
                piece.foregroundColor = STheme.danger
                piece.strikethroughStyle = .single
            case .added:
                piece.foregroundColor = STheme.ok
                piece.backgroundColor = STheme.okBg
            }
            result += piece
        }
        return result
    }
}
