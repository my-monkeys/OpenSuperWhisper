import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenSuperWhisperCore

/// The floating control at the bottom of Home: the trigger on the left (opens the dictation
/// settings), the big record button in the middle, Import on the right. The engine error and the
/// last transient error sit just above it.
struct HomeRecordControl: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var transcription = TranscriptionService.shared
    @ObservedObject private var queue = TranscriptionQueue.shared
    let trigger: HomeTriggerSummary?

    /// The design's warm brown drop shadow (#493322 at 15 %).
    private static let shadow = Color(red: 0x49 / 255, green: 0x33 / 255, blue: 0x22 / 255).opacity(0.15)

    var body: some View {
        VStack(spacing: 10) {
            if let engineError = transcription.engineError {
                ControlNotice(text: engineError, retry: { transcription.reloadEngine() })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let errorMessage = viewModel.errorMessage {
                ControlNotice(text: errorMessage, retry: nil)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            pill
        }
        .animation(.easeInOut, value: transcription.engineError)
        .animation(.easeInOut, value: viewModel.errorMessage)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ControlSegment(edge: .leading, action: { AppNavigation.shared.openSettings(.dictation) }) {
                triggerGlyph
                Text(triggerMode)
            }
            .help(trigger.map { String(localized: "Shortcut: \($0.label). Change it in Settings.") }
                  ?? String(localized: "Set a shortcut in Settings"))
            recordButton
                .zIndex(1)
            ControlSegment(edge: .trailing, action: importAudioFiles) {
                Image(systemName: "square.and.arrow.down")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundColor(STheme.accent)
                Text("Import")
            }
            .help("Transcribe audio files")
        }
        .padding(8)
        .background(Capsule().fill(STheme.cardBg.opacity(0.94)).shadow(color: Self.shadow, radius: 22, y: 18))
        .overlay(Capsule().stroke(STheme.border, lineWidth: 1))
    }

    @ViewBuilder private var triggerGlyph: some View {
        switch trigger?.glyph {
        case .text(let text):
            Text(text)
                .scaledFont(size: 19, weight: .medium)
                .foregroundColor(STheme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        case .symbol(let name):
            Image(systemName: name)
                .scaledFont(size: 18, weight: .medium)
                .foregroundColor(STheme.accent)
        case nil:
            Image(systemName: "keyboard")
                .scaledFont(size: 18, weight: .medium)
                .foregroundColor(STheme.accent)
        }
    }

    private var triggerMode: LocalizedStringKey {
        guard let trigger else { return "Shortcut" }
        return trigger.holds ? "Hold" : "Press"
    }

    private var isBusy: Bool {
        viewModel.state == .decoding || viewModel.state == .connecting || transcription.isLoading
    }

    /// Same conditions as the record button before the redesign.
    private var isDisabled: Bool {
        transcription.isLoading || transcription.isTranscribing || queue.isProcessing
            || viewModel.state == .decoding || transcription.engineError != nil
    }

    private var recordButton: some View {
        Button {
            if viewModel.isRecording {
                viewModel.startDecoding()
            } else {
                viewModel.startRecording()
            }
        } label: {
            RecordButtonFace(isRecording: viewModel.isRecording, isBusy: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(viewModel.isRecording ? "Stop and transcribe" : "Record")
        .accessibilityLabel(viewModel.isRecording ? Text("Stop recording") : Text("Start recording"))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)
    }

    private func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Transcribe")
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    await TranscriptionQueue.shared.addFileToQueue(url: url)
                }
            }
        }
    }
}

/// The terracotta disc: a dot to record, a square to stop, a spinner while busy.
private struct RecordButtonFace: View {
    let isRecording: Bool
    let isBusy: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(hovered && isEnabled ? STheme.accentPressed : STheme.accent)
            if isBusy {
                Spinner()
            } else if isRecording {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(STheme.onAccent)
                    .frame(width: 22, height: 22)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .fill(STheme.onAccent)
                    .frame(width: 20, height: 20)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 72, height: 72)
        .padding(5)
        .background(Circle().fill(STheme.accentSoft))
        .padding(5)
        .background(Circle().fill(STheme.windowBg).shadow(color: STheme.accent.opacity(0.3), radius: 12, y: 10))
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(Circle())
        .onHover { hovered = $0 }
    }
}

private struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(STheme.onAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 24, height: 24)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

/// A beige half-pill tucked under the record button.
private struct ControlSegment<Content: View>: View {
    let edge: HorizontalEdge
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    /// How far the segment slides under the record button, as in the design.
    private static var overlap: CGFloat { 36 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
            }
            .scaledFont(size: 11, weight: .semibold)
            .foregroundColor(STheme.textSecondary)
            .lineLimit(1)
            .frame(minWidth: 94, minHeight: 60)
            .padding(edge == .leading ? .trailing : .leading, Self.overlap + 14)
            .background(shape.fill(hovered ? STheme.border : STheme.fill))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(edge == .leading ? .trailing : .leading, -Self.overlap)
    }

    private var shape: UnevenRoundedRectangle {
        edge == .leading
            ? UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 30, style: .continuous)
            : UnevenRoundedRectangle(bottomTrailingRadius: 30, topTrailingRadius: 30, style: .continuous)
    }
}

/// An error just above the control, with Retry when the model failed to load.
private struct ControlNotice: View {
    let text: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundColor(STheme.warn)
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.sSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.warnBg))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.windowBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.warnBorder, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}
