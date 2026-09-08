import AVFoundation
import Cocoa
import Combine
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case error(String)
    case info(String)
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    // Esc-cancel confirmation: recordings at least this long ask for a second Esc
    // (within the window below) before being discarded, unless the user opted out.
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0

    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    /// The recording has been pinned hands-free and no longer depends on the trigger key.
    @Published var isLatched = false
    @Published var isConfirmingCancel = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    /// The physical notch of the screen this bubble is showing on, nil when that screen has
    /// none. Set at record-start by the window manager, which is the only place that knows
    /// which screen was chosen: a laptop plugged into an external display has one of each.
    @Published var physicalNotch: CGSize?

    var recordingStartedAt: Date?
    /// Set by the trigger when this take should be submitted after insertion (#50). Carried
    /// on the queued clip rather than read at paste time: transcription runs in the
    /// background now, so the next recording may already have started by then.
    var submitAfterInsert = false

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    private var liveStreamingActive = false
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    
    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        state = .busy

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    func showError(_ message: String) {
        state = .error(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    /// Brief, non-alarming notice (e.g. when there was no editable field to paste into).
    func showInfo(_ message: String) {
        state = .info(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }
    
    func startRecording() {
        // No busy check: a previous dictation may still be transcribing in the background
        // (DictationPipeline). Recording is decoupled from transcription, so a new recording
        // can always start — that's the point of parallel recording. (parallel-recording)

        // No input device — surface it instead of optimistically showing "recording" and silently
        // capturing nothing (#157). `getActiveMicrophone()` reads the cached device, so this stays
        // off the blocking AVFoundation path that the hotkey tap must avoid (#freeze).
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showError("No microphone available")
            return
        }

        // Capture where the dictation is happening (frontmost app, browser site/URL,
        // window title) and apply any context-aware model rule before recording. This
        // runs AppleScript/Accessibility synchronously on the main thread; it's quick,
        // but see the note in RecordingContext.captureFrontmost. (F2/F3)
        RecordingContext.shared.captureFrontmost()
        ContextModelSwitcher.applyForCurrentContext()

        // Show recording immediately and optimistically. Whether the mic needs a
        // connection is decided off the main thread inside `recorder.startRecording()`
        // (it touches AVFoundation/CoreAudio, which can stall); the recorder then
        // publishes `isConnecting`/`isRecording` and the Combine bindings above
        // flip this to `.connecting` when needed. Querying it here would put that
        // blocking call on the main thread — and the hotkey tap runs there (#freeze).
        state = .recording
        startBlinking()
        recordingStartedAt = Date()

        Task.detached { [recorder] in
            recorder.startRecording()
        }

        // Live transcription (Parakeet only): stream in parallel with the WAV recorder so the
        // indicator can show the text as the user speaks. Falls back to the file pass on stop.
        // Skipped while ANY transcription is in flight — the background dictation pipeline OR the
        // file-drop `TranscriptionQueue` (`isTranscriptionBusy`) — since the live stream and that
        // pass would otherwise contend on the same engine. The file pass on stop still produces
        // the text; only the on-bubble preview is dropped for this clip. (parallel-recording review)
        if Self.shouldUseLiveStreaming && !DictationPipeline.shared.isProcessing && !isTranscriptionBusy {
            liveStreamingActive = true
            let terms = (AppPreferences.shared.customDictionaryEnabled && AppPreferences.shared.customDictionaryBoostEnabled)
                ? CustomDictionary.boostTerms(entries: AppPreferences.shared.customDictionaryEntries)
                : []
            Task { @MainActor in
                do {
                    try await StreamingTranscriptionController.shared.start(boostTerms: terms)
                } catch {
                    print("Live streaming start failed: \(error)")
                    self.liveStreamingActive = false
                }
            }
        }
    }

    /// Decides what an Esc-cancel should do. Returns `true` when the recording
    /// should be discarded immediately; returns `false` (and arms a short
    /// confirmation window) when a long recording needs a confirming second Esc,
    /// so an accidental tap doesn't throw away a long dictation.
    func handleCancelRequest() -> Bool {
        guard state == .recording,
              !AppPreferences.shared.escCancelWithoutConfirmation,
              !isConfirmingCancel,
              let startedAt = recordingStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.cancelConfirmationThreshold
        else {
            return true
        }

        isConfirmingCancel = true
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelConfirmationWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetCancelConfirmation()
            }
        }
        return false
    }

    private func resetCancelConfirmation() {
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = nil
        isConfirmingCancel = false
    }

    static var shouldUseLiveStreaming: Bool {
        AppPreferences.shared.liveTranscriptionEnabled && AppPreferences.shared.selectedEngine == "fluidaudio"
    }

    /// Real duration of a saved audio file, in seconds (0 if it can't be read).
    nonisolated static func audioDuration(of url: URL) async -> TimeInterval {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        let value = CMTimeGetSeconds(seconds)
        return value.isFinite ? value : 0
    }

    func startDecoding() {
        resetCancelConfirmation()
        stopBlinking()
        isLatched = false

        // Grab the live-streaming preview text (if any) BEFORE cancelling the stream, then hand
        // off. A very short clip can come back empty from the offline file pass even when the
        // sliding-window preview caught it — the pipeline uses this as its fallback. (#short-dictation)
        var streamedFallback = ""
        if liveStreamingActive {
            liveStreamingActive = false
            streamedFallback = StreamingTranscriptionController.shared.liveCaption
            Task { await StreamingTranscriptionController.shared.cancel() }
        }

        guard let tempURL = recorder.stopRecording() else {
            print("!!! Not found record url !!!")
            Diag.mark("vm.startDecoding — no clip returned, nothing to transcribe")
            delegate?.didFinishDecoding()
            return
        }

        // Snapshot the record-start context AND the active model now (both still belong to THIS
        // recording — the next recording's captureFrontmost / model switch hasn't run yet) so the
        // history row and the transcription model stay accurate even though the clip is transcribed
        // later, in the background. (parallel-recording, #model-snapshot)
        let ctx = RecordingContext.shared
        let snapshot = DictationPipeline.ContextSnapshot(
            appName: ctx.appName, bundleID: ctx.bundleID,
            windowTitle: ctx.windowTitle, fullURL: ctx.fullURL)
        let modelOption = ModelCatalog.activeOption()

        // Hand the clip to the background pipeline: it transcribes, saves and pastes on a serial
        // queue in recording-start order, so the user can immediately start the next recording
        // instead of waiting for this one to finish. (parallel-recording)
        DictationPipeline.shared.enqueue(
            tempURL: tempURL,
            startedAt: recordingStartedAt ?? Date(),
            streamedFallback: streamedFallback,
            context: snapshot,
            modelOption: modelOption,
            submitAfterInsert: submitAfterInsert)

        // Free the indicator right away so the next hotkey press starts a fresh recording.
        delegate?.didFinishDecoding()
    }

    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence else { return text }
        // Some models emit run-on sentences with no space after the period ("regularly.Using" — #107).
        // Insert one when a lowercase word-end is immediately followed by sentence punctuation and an
        // uppercase letter; the lowercase/uppercase guard leaves decimals (3.14) and acronyms (U.S.A) alone.
        var result = text.replacingOccurrences(
            of: "([a-z])([.!?])([A-Z])",
            with: "$1$2 $3",
            options: .regularExpression)
        // Trailing space after a finished sentence so the next dictation doesn't run into it.
        if let lastChar = result.last, lastChar.isPunctuation {
            result += " "
        }
        return result
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        resetCancelConfirmation()
        isLatched = false
        recordingStartedAt = nil
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        recorder.cancelRecording()
        if liveStreamingActive {
            liveStreamingActive = false
            Task { await StreamingTranscriptionController.shared.cancel() }
        }
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool
    /// Hands-free: the dot swells, stops blinking and gains a slow outward pulse. The change has to
    /// be legible at a glance and from the corner of the eye — it is the only signal that it is now
    /// safe to let go of the trigger key.
    var isLatched: Bool = false

    @Environment(\.textScaleFactor) private var scale

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: (isLatched ? 11 : 8) * scale, height: (isLatched ? 11 : 8) * scale)
            .shadow(color: .red.opacity(0.5), radius: isLatched ? 6 : 4)
            // Latched reads as steady-and-pulsing rather than blinking: a solid dot says the
            // recording no longer depends on anything being held down.
            .opacity(isLatched ? 1.0 : (isBlinking ? 0.3 : 1.0))
            .overlay { if isLatched { LatchPulse() } }
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isLatched)
    }
}

/// The ring that expands out of the latched dot and fades, once per beat. Deliberately slow: it is
/// an ambient "still going" cue, not something to keep looking at.
private struct LatchPulse: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.55), lineWidth: 1.5)
            .scaleEffect(expanded ? 2.1 : 1)
            .opacity(expanded ? 0 : 0.7)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

/// A thin orange bar that drains left-to-right over the confirmation window,
/// showing how long the "press Esc again to cancel" prompt stays armed.
struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.orange)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .onAppear {
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

/// Pointing-hand cursor while hovering (macOS 14 predates SwiftUI's .pointerStyle).
/// Pops on disappear too, so the cursor never sticks when the bubble goes away
/// mid-hover (e.g. after clicking Stop).
private struct PointerCursorModifier: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}

extension View {
    func pointerCursorOnHover() -> some View { modifier(PointerCursorModifier()) }
}

/// Reports the indicator bubble's laid-out size (before the entrance render transforms) so the
/// window manager can size the panel itself — see the note on `.onPreferenceChange` below.
private struct IndicatorContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    /// Called whenever the bubble's intrinsic size changes. The manager resizes the hosting
    /// window to match, *non-animated* (see `.onPreferenceChange` below for why).
    var onContentResize: (CGSize) -> Void = { _ in }
    @ObservedObject private var streaming = StreamingTranscriptionController.shared
    @ObservedObject private var notch = NotchTuning.shared
    // Surfaces how many earlier clips are still transcribing in the background, so starting a new
    // recording while others are queued shows the backlog. (parallel-recording #3)
    @ObservedObject private var pipeline = DictationPipeline.shared
    @ObservedObject private var spectrum = SpectrumAnalyzer.shared
    @Environment(\.colorScheme) private var colorScheme
    /// Padding and minimum sizes follow the text setting, or the bubble keeps its shipped size
    /// however large the text is set. Notch mode is excluded: its geometry is the hardware's.
    @Environment(\.textScaleFactor) private var scale
    /// How far the opening has travelled past the notch band, 0 to 1. Drives the mask only, never
    /// layout, which is why it is a plain value animated from outside the mask rather than an
    /// animation attached inside it.
    @State private var apronProgress: CGFloat = 0

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }

    /// Wider while live-recording so the growing caption fits inside the bubble; compact otherwise.
    /// Extra width for any enabled on-bubble buttons (Spacer 8 + a 24pt control each) so
    /// they never squeeze the "Recording…" label or the live caption — applies to every
    /// layout, including the notch pill (its base width has no room to spare).
    private var buttonExtraWidth: CGFloat {
        guard viewModel.state == .recording else { return 0 }
        return CGFloat(layout.trailing.count) * 32
    }

    /// Width the chosen elements need beyond a plain dot-and-label bubble, so a composition
    /// with the waveform (or without the label) never squeezes what is left.
    private var meterWidthAllowance: CGFloat {
        guard viewModel.state == .recording else { return 0 }
        return layout.contains(.waveform) && layout.contains(.label) ? 16 : 0
    }

    /// `nil` means "as wide as the contents". The notch keeps a fixed width because it is
    /// imitating a piece of hardware, and the live caption keeps one because text of unknown
    /// length would otherwise resize the window on every word. A plain recording bubble sizes
    /// itself: a fixed 200pt left a waveform-only layout stranded at the left of an
    /// empty pill.
    private var bubbleWidth: CGFloat? {
        let hasCaption = !streaming.confirmedText.isEmpty || !streaming.volatileText.isEmpty
        if isNotchMode {
            return (hasCaption ? max(notch.width, 440) : notch.width) + buttonExtraWidth + meterWidthAllowance
        }
        // The cancel confirmation replaces everything with one short line, and it must be
        // readable whatever was there before: a width chosen for a caption or a meter has no
        // reason to fit it. Hug the sentence instead.
        if viewModel.isConfirmingCancel { return nil }

        let live = viewModel.state == .recording && IndicatorViewModel.shouldUseLiveStreaming
        if live && hasCaption { return 380 + buttonExtraWidth + meterWidthAllowance }
        // Decoding draws the same elements as recording, so it sizes to its content the same
        // way. Pinning it to 200 made the bubble jump wider the moment the user stopped
        // talking. The fixed width is for the message states below, which are prose.
        if viewModel.state == .recording || viewModel.state == .decoding { return nil }
        return 200 + buttonExtraWidth + meterWidthAllowance
    }
    
    private var isNotchMode: Bool { AppPreferences.shared.indicatorPosition == "notch" }

    private var layout: IndicatorLayout {
        IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout)
    }

    /// Bars are allowed to stand taller than the label beside them: the meter is the thing
    /// being read at a glance. Set in the layout editor, where the effect is visible.
    private var meterHeight: CGFloat { layout.waveformHeight }

    private var decodingElements: [IndicatorElement] { layout.decodingLeading }

    /// Opt-in on-bubble controls (default off). Shown on the trailing side while
    /// recording. Stop = stop & transcribe (same as the hotkey toggle); Cancel =
    /// discard (same as the Esc cancel shortcut). Fixed-size, so they don't couple
    /// the bubble's size to the window (see the recursion-crash note above).
    private var anyIndicatorButton: Bool {
        AppPreferences.shared.showStopButtonOnIndicator
            || AppPreferences.shared.showCancelButtonOnIndicator
    }

    @ViewBuilder private var indicatorControls: some View {
        HStack(spacing: 8) {
            if AppPreferences.shared.showStopButtonOnIndicator {
                Button { IndicatorWindowManager.shared.stopRecording() } label: {
                    // A red ring with a red stop square inside (transparent interior).
                    Image(systemName: "stop.circle")
                        .scaledFont(size: 19, weight: .regular)
                        .foregroundColor(.red)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .help("Finish recording")
            }
            if AppPreferences.shared.showCancelButtonOnIndicator {
                Button { IndicatorWindowManager.shared.stopForce() } label: {
                    // A plain red trash can — discard without transcribing.
                    Image(systemName: "trash")
                        .scaledFont(size: 16, weight: .regular)
                        .foregroundColor(.red)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .help("Cancel recording")
            }
        }
    }

    /// The measurements of the screen's cutout, or nil when it has none.
    ///
    /// Everything hardware-shaped hangs off this one optional. A screen without a notch never
    /// gets a value, so it never takes the branch below and keeps the drawn-on pill it has
    /// always had: measurements from one Mac have no business shaping the look on another.
    private var notchGeometry: NotchGeometry? {
        guard isNotchMode else { return nil }
        return NotchGeometry.measure(cutout: viewModel.physicalNotch,
                                     layout: layout,
                                     textScale: CGFloat(scale),
                                     topRadius: CGFloat(notch.topRadius),
                                     bottomRadius: CGFloat(notch.bottomRadius))
    }

    var body: some View {
        if let geometry = notchGeometry {
            notchBubble(geometry)
        } else {
            classicBubble
        }
    }

    @ViewBuilder private var classicBubble: some View {

        // Notch mode uses the real notch silhouette (concave top wings + rounded bottom).
        let rect: AnyShape = isNotchMode
            ? AnyShape(NotchShape(topRadius: notch.topRadius, bottomRadius: notch.bottomRadius))
            : AnyShape(RoundedRectangle(cornerRadius: 24))

        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .scaledFont(size: 13, weight: .semibold)
                }                
            case .recording:
                if viewModel.isConfirmingCancel {
                    // Takes over the whole bubble, above the meter and above a live caption
                    // alike. It used to live inside the no-caption branch only, so on an engine
                    // that streams text the first Esc looked like nothing had happened and the
                    // second one threw the dictation away unannounced.
                    Text("Press Esc to cancel")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                } else if streaming.confirmedText.isEmpty && streaming.volatileText.isEmpty {
                    // Before any text arrives, just the dot + label, vertically centered.
                    HStack(alignment: .center, spacing: 10) {
                        ForEach(layout.leading) { element in
                            IndicatorElementView(element: element,
                                                 bands: spectrum.bands,
                                                 meterHeight: meterHeight,
                                                 isBlinking: viewModel.isBlinking,
                                                 isLatched: viewModel.isLatched,
                                                 queued: pipeline.pendingCount)
                        }
                        if !layout.trailing.isEmpty {
                            Spacer(minLength: 8)
                            HStack(spacing: 8) {
                                ForEach(layout.trailing) { element in
                                    IndicatorElementView(element: element,
                                                         bands: spectrum.bands,
                                                         meterHeight: meterHeight,
                                                         isBlinking: viewModel.isBlinking,
                                                         isLatched: viewModel.isLatched,
                                                         queued: pipeline.pendingCount)
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
                } else {
                    // Once text starts, drop the label: just the dot + the text, which grows
                    // (the window resizes to fit it) so everything stays visible.
                    // Center-aligned: with the (taller) on-bubble buttons enabled, .top
                    // alignment pinned a single caption line above the vertical middle.
                    HStack(alignment: .center, spacing: 10) {
                        RecordingIndicator(isBlinking: viewModel.isBlinking, isLatched: viewModel.isLatched)
                            .frame(width: 16)
                        (Text(streaming.confirmedText).foregroundColor(.primary)
                            + Text(streaming.confirmedText.isEmpty ? "" : " ")
                            + Text(streaming.volatileText).foregroundColor(.secondary))
                            .scaledFont(size: 14)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                        if anyIndicatorButton {
                            Spacer(minLength: 8)
                            indicatorControls
                        }
                    }
                }

            case .decoding:
                // Built from the user's own layout so the bubble keeps its shape: whoever chose
                // the meter gets a spinner of the same width, whoever chose the label gets
                // different words, whoever chose both gets both. The stop and cancel buttons
                // drop out, since there is no longer anything to stop.
                HStack(alignment: .center, spacing: 10) {
                    ForEach(decodingElements) { element in
                        IndicatorElementView(element: element,
                                             meterHeight: meterHeight,
                                             queued: pipeline.pendingCount,
                                             isDecoding: true)
                    }
                    if !layout.trailing.isEmpty {
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            ForEach(layout.trailing) { element in
                                IndicatorElementView(element: element,
                                                     meterHeight: meterHeight,
                                                     queued: pipeline.pendingCount,
                                                     isDecoding: true)
                            }
                        }
                    }
                }
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.orange)
                        .frame(width: 24)
                    
                    Text("Processing...")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.orange)
                }                
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .frame(width: 24)

                    Text(message)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.red)
                }
            case .info(let message):
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    Text(message)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.primary)
                }
            case .idle:
                EmptyView()
            }
        }
        // Without a fixed width the HStack takes whatever the window offers and the trailing
        // Spacer eats it, so a waveform plus two buttons stretched into a mostly empty bar.
        // Fixing the horizontal size collapses the Spacer to its 8pt minimum.
        .fixedSize(horizontal: bubbleWidth == nil, vertical: false)
        .padding(.horizontal, isNotchMode ? 22 : 16 * scale)
        .padding(.vertical, isNotchMode ? 10 : 7 * scale)
        // Width must be set *before* the background so the bubble itself fills it (not just the
        // surrounding frame). Notch content is centred; the others stay leading.
        .frame(minHeight: isNotchMode ? notch.height : 36 * scale)
        // A floor so a single small element still reads as a bubble rather than a chip.
        .frame(minWidth: bubbleWidth == nil ? 76 * scale : nil)
        .frame(width: bubbleWidth, alignment: isNotchMode ? .center : .leading)
        .background {
            if isNotchMode {
                rect
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            } else {
                rect
                    .fill(backgroundColor)
                    .background {
                        rect
                            .fill(Material.thinMaterial)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isConfirmingCancel {
                CancelConfirmationBar()
            }
        }
        .clipShape(rect)
        // Measure the bubble here, *before* the entrance transforms below, so the reported size is
        // the real layout size (scaleEffect/offset are render-only and don't affect this).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: IndicatorContentSizeKey.self, value: proxy.size)
            }
        )
        .environment(\.colorScheme, isNotchMode ? .dark : colorScheme)
        // Notch drops in from the top edge; the others rise from below.
        .scaleEffect(viewModel.isVisible ? 1 : (isNotchMode ? 0.85 : 0.5), anchor: isNotchMode ? .top : .center)
        .offset(y: viewModel.isVisible ? 0 : (isNotchMode ? -20 : 20))
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: viewModel.isVisible)
        // The hosting window is sized by the manager from this preference (NOT by SwiftUI's
        // `.preferredContentSize` auto-resize). That auto-resize runs *animated* whenever any
        // SwiftUI animation transaction is active during a layout pass (NSHostingView
        // .updateAnimatedWindowSize), and on macOS 26 the animated resize re-enters layout and
        // recurses until the main-thread stack overflows — the crash in #11/#15/#19. Driving the
        // size ourselves, non-animated, makes that recursion impossible, so the entrance spring
        // and the blinking dot above are free to animate without risk.
        .onPreferenceChange(IndicatorContentSizeKey.self) { size in
            onContentResize(size)
        }
        .onAppear {
            viewModel.isVisible = true
        }
    }

    // MARK: - Around a real notch

    /// The bubble on a Mac that has a cutout: one width, whatever it is showing, and a height
    /// that grows only when there is something the notch cannot hold.
    ///
    /// The small fixed elements go either side of the hardware, which is where the menu bar has
    /// room to spare. Prose goes underneath, because a sentence laid out astride a hole loses its
    /// middle. Nothing here is narrower than the notch: the width has a floor that accounts for
    /// the silhouette's inward-curving wings, so the black always reaches past the glass.
    private func notchBubble(_ geometry: NotchGeometry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                notchFlank(geometry: geometry, alignment: .trailing) {
                    notchLeadingContent(geometry)
                }
                // The hardware itself. Reserved on both sides even when only one of them has
                // anything in it, or the hole slides off the notch by half the missing width.
                Color.clear
                    .frame(width: geometry.cutout.width, height: geometry.bandHeight)
                notchFlank(geometry: geometry, alignment: .leading) {
                    notchElements(notchTrailingElements, geometry: geometry)
                }
            }
            .frame(height: geometry.bandHeight)

            if hasNotchApron {
                notchApron
                    .padding(.horizontal, 18)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: geometry.width)
        .background { notchSilhouette(geometry).fill(.black) }
        .environment(\.colorScheme, .dark)
        // Measured here, before the mask, which is render-only. Nothing about the entrance may
        // reach this: the manager resizes the window from it, and a size that animates would
        // feed a stream of window resizes back into layout (the macOS 26 recursion, #19).
        .overlay(
            GeometryReader { proxy in
                Color.clear.preference(key: IndicatorContentSizeKey.self, value: proxy.size)
            }
            .allowsHitTesting(false)
        )
        // The opening the bubble is seen through. A mask rather than a transform, so the bubble
        // is uncovered at its final size instead of being squashed into the notch and stretched
        // back out. It carries the entrance and every later change of height: the window snaps,
        // deliberately, and the mask is what makes that read as the pill growing.
        .mask {
            // The height is read here rather than measured a frame earlier, so the opening is
            // always the bubble's real height and can never clip what the bubble is saying. An
            // earlier version drove it from the size reported for the window, which arrives late,
            // and the message was invisible until it caught up.
            //
            // There is deliberately no `.animation` inside here. Any animation modifier in this
            // GeometryReader leaks into layout, whatever value drives it, and then the bubble
            // itself grows over 40 frames inside a window that snapped to full height in one.
            // SwiftUI centres content smaller than its frame, so the pill appeared to swell out
            // of the middle of the notch in both directions at once, with a gap showing the
            // desktop through the middle. The animation lives in `apronProgress` instead, set
            // from `.onChange` below, which runs after layout has already settled.
            GeometryReader { proxy in
                NotchReveal(width: viewModel.isVisible ? geometry.width : geometry.cutout.width,
                            height: openHeight(geometry, full: proxy.size.height),
                            topRadius: geometry.topRadius,
                            bottomRadius: geometry.bottomRadius)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: viewModel.isVisible)
        .onPreferenceChange(IndicatorContentSizeKey.self) { size in
            onContentResize(size)
        }
        // Set here rather than inside the mask so the bubble's own layout has already settled,
        // unanimated, by the time this runs. That ordering is the whole trick: the height snaps,
        // and only the opening over it travels.
        .onChange(of: hasNotchApron) { _, showing in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                apronProgress = showing ? 1 : 0
            }
        }
        .onAppear {
            viewModel.isVisible = true
            if hasNotchApron { apronProgress = 1 }
        }
    }

    /// How far down the opening reaches.
    ///
    /// Closed it is the cutout, so the first frame is indistinguishable from the hardware. Open it
    /// is the band alone when nothing hangs below, and the bubble's whole measured height when
    /// something does.
    private func openHeight(_ geometry: NotchGeometry, full: CGFloat) -> CGFloat {
        guard viewModel.isVisible else { return geometry.cutout.height }
        return geometry.openHeight(progress: apronProgress, full: full)
    }

    /// A symbol and its message on one line, the symbol centred on the first line of text so a
    /// message that wraps still reads as one block rather than as a symbol with a paragraph
    /// hanging off it.
    private func messageLine(_ symbol: (name: String, color: Color)?, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let symbol {
                Image(systemName: symbol.name)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(symbol.color)
            }
            text
                .scaledFont(size: 13, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notchSilhouette(_ geometry: NotchGeometry) -> NotchShape {
        NotchShape(topRadius: geometry.topRadius, bottomRadius: geometry.bottomRadius)
    }

    /// One side of the cutout, at the fixed width both sides share.
    ///
    /// Content hugs the hardware, so the bubble reads as one object wrapped around the notch
    /// rather than two islands adrift at the far edges. The slack goes to the outer edges, in
    /// equal parts, which is what keeps the hole over the glass.
    private func notchFlank<Content: View>(geometry: NotchGeometry, alignment: Alignment,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(alignment == .trailing ? .trailing : .leading, NotchGeometry.innerGutter)
            .frame(width: geometry.sideWidth, height: geometry.bandHeight, alignment: alignment)
    }

    private func notchElements(_ elements: [IndicatorElement],
                               geometry: NotchGeometry) -> some View {
        HStack(spacing: NotchGeometry.elementSpacing) {
            ForEach(elements) { element in
                IndicatorElementView(element: element,
                                     bands: spectrum.bands,
                                     meterHeight: notchMeterHeight(geometry),
                                     isBlinking: viewModel.isBlinking,
                                     isLatched: viewModel.isLatched,
                                     queued: pipeline.pendingCount,
                                     isDecoding: viewModel.state == .decoding)
            }
        }
    }

    /// What sits beside the notch, whatever the bubble is doing.
    ///
    /// Every state puts something here, and that is the point. The bubble is one object that
    /// stays up from the moment you start speaking until the moment it goes away, so the band
    /// beside the hardware must never go empty: a message used to clear both flanks, and since
    /// the band itself is hidden behind the notch, the bubble read as having closed and then
    /// reopened underneath. The words go below; what is happening stays up here.
    @ViewBuilder private func notchLeadingContent(_ geometry: NotchGeometry) -> some View {
        switch viewModel.state {
        case .connecting:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .idle:
            EmptyView()
        default:
            // `decodingLeading` rather than `leading` because it is the one that is never empty:
            // a layout with neither meter nor label borrows the meter, and an empty flank means
            // an invisible bubble. While a message is up the meter is simply at rest, which is
            // both true and continuous with what was there a moment earlier.
            notchElements(layout.decodingLeading, geometry: geometry)
        }
    }

    /// The symbol that goes beside a message, or nil for a state that has no words.
    private var notchMessageSymbol: (name: String, color: Color)? {
        switch viewModel.state {
        case .busy: return ("hourglass", .orange)
        case .error: return ("exclamationmark.triangle.fill", .red)
        case .info: return ("info.circle", .white)
        case .connecting, .recording, .decoding, .idle: return nil
        }
    }

    /// The meter is the tallest thing on the row and the row is the height of the cutout, so a
    /// taller setting would stand the bars out from under the hardware instead of inside it.
    private func notchMeterHeight(_ geometry: NotchGeometry) -> CGFloat {
        min(meterHeight, geometry.bandHeight - 10)
    }

    private var notchTrailingElements: [IndicatorElement] {
        switch viewModel.state {
        case .recording, .decoding: return layout.trailing
        case .idle, .connecting, .busy, .error, .info: return []
        }
    }

    /// Whether anything hangs below the hardware. When nothing does, the bubble is exactly the
    /// cutout's height and the only thing on screen is what flanks it.
    private var hasNotchApron: Bool {
        switch viewModel.state {
        case .recording:
            return viewModel.isConfirmingCancel
                || !streaming.confirmedText.isEmpty
                || !streaming.volatileText.isEmpty
        case .connecting, .busy, .error, .info:
            return true
        case .idle, .decoding:
            return false
        }
    }

    /// Everything made of words. It keeps the width the bubble already had and takes the height
    /// it needs, which is the one direction there is room to grow in.
    @ViewBuilder private var notchApron: some View {
        switch viewModel.state {
        case .recording:
            if viewModel.isConfirmingCancel {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Press Esc to cancel")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                    CancelConfirmationBar()
                }
            } else {
                (Text(streaming.confirmedText).foregroundColor(.primary)
                    + Text(streaming.confirmedText.isEmpty ? "" : " ")
                    + Text(streaming.volatileText).foregroundColor(.secondary))
                    .scaledFont(size: 13)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        // The symbol sits on the same line as the words it belongs to, not up in the band. Up
        // there it read as an orphan on a line of its own, with the message stranded below it.
        case .connecting:
            messageLine(nil, Text("Connecting...").foregroundColor(.primary))
        case .busy:
            messageLine(notchMessageSymbol, Text("Processing...").foregroundColor(.orange))
        case .error(let message):
            messageLine(notchMessageSymbol, Text(message).foregroundColor(.red))
        case .info(let message):
            messageLine(notchMessageSymbol, Text(message).foregroundColor(.primary))
        case .idle, .decoding:
            EmptyView()
        }
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.startDecoding()
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
