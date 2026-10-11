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
    @ObservedObject private var audioRecorder = AudioRecorder.shared
    @State private var isExpanded = false
    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var isRegenerating: Bool { recording.isRegeneration && recording.isPending }

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
                        FeedRowMeta(recording: recording)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        actions
                    }
                } else {
                    FeedRowMeta(recording: recording)
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
                       isRegenerating: isRegenerating, onDelete: onDelete, onRegenerate: onRegenerate)
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
            .help(recording.wasFallback ? String(localized: "Local fallback — the remote server was unreachable") : "")
    }

    private var line: Text {
        var parts: [Text] = []
        if let source { parts.append(Text(source)) }
        if let model = recording.modelUsed {
            parts.append(recording.wasFallback ? Text(model).foregroundColor(STheme.warn) : Text(model))
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

/// Copy, play, regenerate and delete. Laid out on every row so the text never re-wraps when
/// they appear; only visible on hover (and while playing, or when there is nothing else to do
/// with a queued or failed row but delete it).
private struct FeedRowActions: View {
    let recording: Recording
    let isHovered: Bool
    let isPlaying: Bool
    let isRegenerating: Bool
    let onDelete: () -> Void
    let onRegenerate: (DictationModelOption?) -> Void
    @State private var copied = false

    private var canPlayAndCopy: Bool { !recording.isPending && recording.status != .failed }
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
                Menu {
                    Button("Current model") { onRegenerate(nil) }
                    let models = ModelCatalog.allAvailable()
                    if !models.isEmpty {
                        Divider()
                        ForEach(models.indices, id: \.self) { i in
                            Button(models[i].displayName) { onRegenerate(models[i]) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .modifier(ActionChrome())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Regenerate, with the current model or another one")
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

    func body(content: Content) -> some View {
        content
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(tint ?? STheme.textSecondary)
            .frame(minWidth: 14, minHeight: 16)
            .padding(.horizontal, 9).padding(.vertical, 5)
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
