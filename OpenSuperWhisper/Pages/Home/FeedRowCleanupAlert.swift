import SwiftUI
import OpenSuperWhisperCore

/// A dictation whose AI cleanup failed, flagged where the eye lands: a warning sign in the meta
/// line that opens what went wrong. The tinted words alone read as one more detail of the line,
/// and a cleanup that failed on every long dictation went unnoticed (feedback of 2026-11-11).
struct FeedRowCleanupAlert: View {
    let recording: Recording
    let model: String
    let reason: String
    let onCleanup: (HistoryRestyle.Request) -> Void
    @Environment(\.appTextScale) private var textScale
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Cleanup failed")
            }
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(STheme.warn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See why the AI cleanup failed")
        .fixedSize()
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            FeedRowCleanupAlertPanel(recording: recording, model: model, reason: reason,
                                     onCleanup: onCleanup, onClose: { isShown = false })
                .environment(\.appTextScale, textScale)
        }
    }
}

/// What the warning opens: the model, its reason, what was kept instead, and the two ways out.
struct FeedRowCleanupAlertPanel: View {
    let recording: Recording
    let model: String
    let reason: String
    let onCleanup: (HistoryRestyle.Request) -> Void
    let onClose: () -> Void
    @Environment(\.appTextScale) private var textScale

    /// The style the row was written in, else the default: what the dictation itself would use.
    private var style: WritingStyle {
        let styles = WritingStyle.builtIns + AppPreferences.shared.customWritingStyles
        return styles.first { WritingStyleText.name($0) == recording.styleUsed }
            ?? AppPreferences.shared.writingStyle(for: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(STheme.warn)
                Text("AI cleanup failed")
                    .foregroundColor(STheme.textBright)
            }
            .scaledFont(size: 14, weight: .semibold)
            Text("Cleanup with \(model) failed: \(reason). The text is what the engine heard.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if HistoryRestyle.isAvailable(for: recording) {
                    Button("Retry") {
                        onCleanup(HistoryRestyle.Request(style: style))
                        onClose()
                    }
                    .buttonStyle(.sPrimary)
                }
                Button("AI settings") {
                    AppNavigation.shared.openSettings(.textAndAI, focusing: "Format with AI")
                    onClose()
                }
                .buttonStyle(.sSecondary)
            }
        }
        .padding(14)
        .frame(width: 320 * textScale, alignment: .leading)
        .background(STheme.windowBg)
    }
}
