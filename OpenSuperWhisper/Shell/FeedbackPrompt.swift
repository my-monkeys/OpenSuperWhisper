import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Asking, once per campaign, for feedback (#206). The Feedback card is only found by those who
/// look for it, so the app opens it itself one time, with a note on top saying why. Whether they
/// then send, cancel or close it, that campaign is never asked again.
///
/// The campaign now is the bug hunt: the update after 0.15.0 is about stability, and a report
/// with an email to answer is worth more than a guess at what went wrong. It is asked the first
/// time the main window comes up after the update, including in a launch that started in the
/// menu bar, which is how most people run a dictation app.
///
/// The decision is `shouldAsk`, a function of plain values. `FeedbackPromptScheduler` gathers
/// them from the app and opens the card.
enum FeedbackPrompt {
    /// Stored in `AppPreferences.feedbackPromptCampaign` once asked or answered. A new campaign
    /// is a new name, and the note on the card says what it is about.
    static let campaign = "bug-hunt-2026-11"

    /// How long the main window has to stay in front before the card opens: not the first thing
    /// on screen, and not over a window someone has just brought up to do something else.
    static let settleDelay: Duration = .seconds(4)

    struct Moment: Equatable {
        /// This campaign was asked before, or feedback was sent since it began.
        var done: Bool
        /// Onboarding was done when this launch started. False through the launch that runs it,
        /// even once it is finished and the main window has taken over.
        var onboardedAtLaunch: Bool
        /// The main window is visible and key, in the active app, with no sheet or alert over it.
        var windowInFront: Bool
        /// Home, with the search field empty: not the dictionary editor or a style picker, and
        /// not someone typing a search.
        var onQuietHome: Bool
        /// The settings, Help or Feedback card is open.
        var cardOpen: Bool
        /// A recording, a dictation or a file being transcribed, a model loading, or a
        /// recording playing back.
        var busy: Bool
    }

    static func shouldAsk(_ moment: Moment) -> Bool {
        !moment.done
            && moment.onboardedAtLaunch
            && moment.windowInFront
            && moment.onQuietHome
            && !moment.cardOpen
            && !moment.busy
    }

    /// Whether `stored`, the campaign last asked or answered, is this one. An answer to an
    /// earlier campaign does not count.
    static func isDone(stored: String?) -> Bool {
        stored == campaign
    }

    /// Feedback sent from anywhere answers the campaign: the card is never opened on its own.
    @MainActor
    static func markDone() {
        AppPreferences.shared.feedbackPromptCampaign = campaign
    }
}

/// Watches the main window and opens the Feedback card in its asked mode when
/// `FeedbackPrompt.shouldAsk` says so. Never in a test process: the hosted tests and the
/// snapshot probe draw the main window too, and must not open cards or write preferences.
@MainActor
final class FeedbackPromptScheduler {
    static let shared = FeedbackPromptScheduler()

    /// Whether onboarding was done when this launch started. Nil until `recordLaunch`, and for
    /// good in a test process: nothing is asked without it.
    private var onboardedAtLaunch: Bool?
    private weak var window: NSWindow?
    private var keyObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    private init() {}

    /// From `applicationDidFinishLaunching`.
    func recordLaunch(onboarded: Bool) {
        guard !DefaultsStore.isRunningTests else { return }
        onboardedAtLaunch = onboarded
    }

    /// The main window's content joined a window, or left it (nil).
    func attach(_ window: NSWindow?) {
        guard !DefaultsStore.isRunningTests, window !== self.window else { return }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        pending?.cancel()
        self.window = window
        guard let window, !Self.isDone else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        scheduleCheck()
    }

    /// Every time the window comes to the front, a look once it has stayed there a moment.
    /// Bringing it forward again starts the wait over.
    private func scheduleCheck() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: FeedbackPrompt.settleDelay)
            guard !Task.isCancelled else { return }
            self?.askIfTheMomentIsRight()
        }
    }

    private func askIfTheMomentIsRight() {
        guard let moment = currentMoment(), FeedbackPrompt.shouldAsk(moment) else { return }
        Self.ask(prefs: .shared, navigation: .shared)
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    /// Recorded before the card opens: whatever happens next, it is never shown again.
    static func ask(prefs: AppPreferences, navigation: AppNavigation) {
        prefs.feedbackPromptCampaign = FeedbackPrompt.campaign
        navigation.askForFeedback()
    }

    private static var isDone: Bool {
        FeedbackPrompt.isDone(stored: AppPreferences.shared.feedbackPromptCampaign)
    }

    private func currentMoment() -> FeedbackPrompt.Moment? {
        guard let onboardedAtLaunch, let window else { return nil }
        let navigation = AppNavigation.shared
        let recorder = AudioRecorder.shared
        return FeedbackPrompt.Moment(
            done: Self.isDone,
            onboardedAtLaunch: onboardedAtLaunch,
            windowInFront: NSApp.isActive && NSApp.modalWindow == nil && window.isVisible
                && window.isKeyWindow && window.attachedSheet == nil,
            onQuietHome: navigation.page == .home && navigation.searchText.isEmpty,
            cardOpen: navigation.helpOpen || navigation.feedbackOpen
                || navigation.reporting != nil || navigation.reportsOpen,
            busy: recorder.isRecording || recorder.isConnecting || recorder.isPlaying
                || IndicatorWindowManager.shared.viewModel != nil
                || DictationPipeline.shared.isProcessing
                || TranscriptionQueue.shared.isProcessing
                || TranscriptionService.shared.isLoading
                || FileDropHandler.shared.isDragging)
    }
}

/// Tells the scheduler which window the main window's content is in, as AppKit attaches it:
/// SwiftUI owns that window and never hands it over.
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: @MainActor (NSWindow?) -> Void

        init(onWindow: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// Behind the whole window: it must never be the view a click or a drop lands on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

extension View {
    /// On the main window's content: lets the app ask for feedback once, when the time is right.
    func asksForFeedbackOnce() -> some View {
        background(HostWindowReader { FeedbackPromptScheduler.shared.attach($0) })
    }
}
