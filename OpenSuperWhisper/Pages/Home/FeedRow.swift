import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// One dictation in the Home feed: time, text, where it came from; the actions show on hover.
struct FeedRow: View {
    let recording: Recording
    let searchQuery: String
    /// Narrow window or large text: the actions move onto the meta line so the text keeps its
    /// width instead of wrapping every few words beside a column of buttons.
    let compact: Bool
    let onDelete: () -> Void
    /// nil → rerun with the current model; otherwise rerun once with that model. (F3)
    let onRegenerate: (DictationModelOption?) -> Void
    /// Runs the AI cleanup again on the engine's text, without transcribing again (#160, #276).
    let onCleanup: (HistoryRestyle.Request) -> Void
    let onReport: () -> Void
    @ObservedObject private var audioRecorder = AudioRecorder.shared
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var showsOriginal = FeedRow.initiallyShowsOriginal

    #if DEBUG
    /// For the snapshot probe, which shows the original unfolded.
    static var snapshotShowsOriginals = false
    #endif

    private static var initiallyShowsOriginal: Bool {
        #if DEBUG
        return snapshotShowsOriginals
        #else
        return false
        #endif
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var isRegenerating: Bool { recording.isRegeneration && recording.isPending }

    /// The engine's text, offered only on a finished row whose text it is not.
    private var original: String? {
        recording.status == .completed && !isRegenerating ? recording.distinctOriginal : nil
    }

    private var displayText: String {
        let text = recording.transcription
        if text.isEmpty || text == "Starting transcription..." || text == "In queue..." { return "" }
        // A finished import whose text is only its own file name says nothing the title doesn't.
        if text == recording.sourceFileName { return "" }
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(Self.timeFormatter.string(from: recording.timestamp))
                .scaledFont(size: 13)
                .monospacedDigit()
                .foregroundColor(STheme.hint)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                content
                if recording.isPending || isRegenerating {
                    FeedRowProgress(recording: recording)
                }
                if compact {
                    HStack(alignment: .center, spacing: 12) {
                        metaLine
                            .frame(maxWidth: .infinity, alignment: .leading)
                        actions
                    }
                } else {
                    metaLine
                }
                if showsOriginal, let original {
                    FeedRowOriginalText(original: original, cleaned: recording.transcription,
                                    cleanupModel: recording.cleanupModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                actions
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isHovered ? STheme.accentTint : Color.clear))
        .padding(.horizontal, -16)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var actions: some View {
        FeedRowActions(recording: recording, isHovered: isHovered, isPlaying: isPlaying,
                       isRegenerating: isRegenerating, onDelete: onDelete, onRegenerate: onRegenerate,
                       onCleanup: onCleanup, onReport: onReport)
    }

    private var metaLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            FeedRowMeta(recording: recording)
            if original != nil {
                FeedRowOriginalToggle(isShown: $showsOriginal)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let fileName = recording.sourceFileName {
            Text(fileName)
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(STheme.textBright)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if recording.status == .failed {
            Text("Transcription failed")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(STheme.warn)
            // What the engine said, or managed, before failing.
            if !recording.transcription.isEmpty {
                Text(recording.transcription)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else if !displayText.isEmpty {
            CollapsibleTranscript(text: displayText, searchQuery: searchQuery, isExpanded: $isExpanded)
                .overlay {
                    if isRegenerating {
                        ShimmerOverlay()
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                }
        } else if !recording.isPending && recording.sourceFileName == nil {
            Text("No speech detected")
                .scaledFont(size: 15)
                .foregroundColor(STheme.hint)
        }
    }
}

/// "Mail · Parakeet v3 · 6s": where the text went, which model wrote it, how long it lasted.
private struct FeedRowMeta: View {
    let recording: Recording

    /// Target app · site, or "Imported file" for a dropped or imported audio file.
    private var source: String? {
        if recording.sourceFileURL != nil { return String(localized: "Imported file") }
        let site = SourceCapture.host(of: recording.sourceURL) ?? recording.sourceWindowTitle
        let context = [recording.sourceAppName, site].compactMap { $0 }.joined(separator: " · ")
        return context.isEmpty ? nil : context
    }

    var body: some View {
        line
            .scaledFont(size: 12)
            .foregroundColor(STheme.hint)
            .lineLimit(2)
            .help(tooltip)
    }

    /// What the line cannot fit: why the model is tinted, and which model cleaned the text or why
    /// it failed.
    private var tooltip: String {
        var lines: [String] = []
        if recording.wasFallback { lines.append(String(localized: "Local fallback — the remote server was unreachable")) }
        if let model = recording.cleanupModel {
            lines.append(recording.cleanupError.map { String(localized: "Cleanup with \(model) failed: \($0). The text is what the engine heard.") }
                         ?? String(localized: "Cleaned up with \(model)"))
        }
        return lines.joined(separator: "\n")
    }

    private var line: Text {
        var parts: [Text] = []
        if let source { parts.append(Text(source)) }
        if let model = recording.modelUsed {
            parts.append(recording.wasFallback ? Text(model).foregroundColor(STheme.warn) : Text(model))
        }
        if let style = recording.styleUsed { parts.append(Text(style)) }
        if recording.cleanupModel != nil {
            parts.append(recording.cleanupError == nil
                         ? Text("Cleaned up")
                         : Text("Cleanup failed").foregroundColor(STheme.warn))
        }
        if recording.duration > 0 { parts.append(Text(TextUtil.formatDuration(recording.duration))) }
        guard var line = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() {
            line = line + Text(verbatim: " · ") + part
        }
        return line
    }
}

/// Live progress of the row being (re)transcribed: ring, percentage, elapsed time, status.
private struct FeedRowProgress: View {
    let recording: Recording
    @ObservedObject private var queue = TranscriptionQueue.shared

    private var statusText: LocalizedStringKey {
        switch recording.status {
        case .pending: return "In queue..."
        case .converting: return "Converting..."
        case .transcribing: return "Transcribing..."
        case .completed, .failed: return ""
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if recording.status == .pending {
                Image(systemName: "clock")
                    .scaledFont(size: 12)
            } else {
                ZStack {
                    Circle().stroke(STheme.track, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(recording.progress))
                        .stroke(STheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recording.progress)
                }
                .frame(width: 14, height: 14)
                Text(verbatim: "\(Int(recording.progress * 100))%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
                elapsed
            }
            Text(statusText)
        }
        .scaledFont(size: 12)
        .foregroundColor(STheme.hint)
        .transition(.opacity)
    }

    /// Time since processing started, for the row currently being transcribed (#87).
    @ViewBuilder private var elapsed: some View {
        if recording.id == queue.currentRecordingId, let startedAt = queue.processingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let secs = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text(verbatim: String(format: "%d:%02d", secs / 60, secs % 60))
                    .monospacedDigit()
            }
        }
    }
}

/// Copy, play, regenerate, report and delete. Laid out on every row so the text never re-wraps
/// when they appear; only visible on hover (and while playing, or when there is nothing else to
/// do with a queued or failed row but delete it).
private struct FeedRowActions: View {
    let recording: Recording
    let isHovered: Bool
    let isPlaying: Bool
    let isRegenerating: Bool
    let onDelete: () -> Void
    let onRegenerate: (DictationModelOption?) -> Void
    let onCleanup: (HistoryRestyle.Request) -> Void
    let onReport: () -> Void
    @Environment(\.appTextScale) private var textScale
    @State private var copied = false
    @State private var showsPanel = false

    private var canPlayAndCopy: Bool { !recording.isPending && recording.status != .failed }
    /// A failed dictation is reportable too: a slow one that then failed is exactly what #262 is
    /// about, and its row already carries the engine's reason as the transcription text.
    private var canReport: Bool {
        (recording.status == .completed || recording.status == .failed)
            && !recording.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canRegenerate: Bool { recording.status == .completed || recording.status == .failed }
    private var deleteAlwaysVisible: Bool {
        (recording.isPending && !isRegenerating) || recording.status == .failed
    }

    var body: some View {
        HStack(spacing: 6) {
            if canPlayAndCopy {
                Button(action: copy) {
                    Text(copied ? "Copied" : "Copy")
                        .modifier(ActionChrome())
                }
                .buttonStyle(.plain)
                .help("Copy entire text")
                .visible(isHovered || isPlaying)

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .modifier(ActionChrome(tint: isPlaying ? STheme.accent : nil))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Stop" : "Play the recording")
                .visible(isHovered || isPlaying)
            }
            if canRegenerate {
                // A click reruns with the model in use, which is what a failed row needs nine times
                // out of ten; the chevron opens the panel for another model or another cleanup.
                HStack(spacing: 2) {
                    Button { onRegenerate(nil) } label: {
                        Image(systemName: "arrow.clockwise")
                            .modifier(ActionChrome())
                    }
                    .buttonStyle(.plain)
                    .help("Regenerate with the current model")
                    Button { showsPanel.toggle() } label: {
                        Image(systemName: "chevron.down")
                            .modifier(ActionChrome(compact: true))
                    }
                    .buttonStyle(.plain)
                    .help("Regenerate with another model, or run the AI cleanup again")
                    .accessibilityLabel(Text("More ways to regenerate"))
                    .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
                        RegeneratePanel(recording: recording, onRegenerate: onRegenerate, onCleanup: onCleanup,
                                        onClose: { showsPanel = false })
                            .environment(\.appTextScale, textScale)
                    }
                }
                .visible(isHovered || showsPanel)
            }
            if canReport {
                Button(action: onReport) {
                    Image(systemName: "flag")
                        .modifier(ActionChrome())
                }
                .buttonStyle(.plain)
                .help("Report a bad transcription")
                .accessibilityLabel(Text("Report a bad transcription"))
                .visible(isHovered)
            }
            Button {
                if isPlaying { AudioRecorder.shared.stopPlaying() }
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .modifier(ActionChrome())
            }
            .buttonStyle(.plain)
            .help("Delete")
            .visible(isHovered || isPlaying || deleteAlwaysVisible)
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isPlaying)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.transcription, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func togglePlayback() {
        if isPlaying {
            AudioRecorder.shared.stopPlaying()
        } else {
            AudioRecorder.shared.playRecording(url: recording.url)
        }
    }
}

/// The small bordered cream button of the row actions.
private struct ActionChrome: ViewModifier {
    var tint: Color? = nil
    /// The chevron beside a button: narrower, so the pair reads as one control.
    var compact = false

    func body(content: Content) -> some View {
        content
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(tint ?? STheme.textSecondary)
            .frame(minWidth: 14, minHeight: 16)
            .padding(.horizontal, compact ? 5 : 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(STheme.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(STheme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

private extension View {
    /// Keeps the view's place in the layout while hidden.
    func visible(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
