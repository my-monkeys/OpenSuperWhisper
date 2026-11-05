import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Asking, once ever, for feedback on the interface rebuilt in 0.14 (#206). The Feedback card is
/// only found by those who look for it, so the app opens it itself one time, with a note on top,
/// for anyone who has never sent feedback. Whether they then send, cancel or close it, it is
/// never asked again.
///
/// The decision is `shouldAsk`, a function of plain values. `FeedbackPromptScheduler` gathers
/// them from the app and opens the card.
enum FeedbackPrompt {
    /// Launches, this one included, that must have started with onboarding already done. Two
    /// rather than one: someone updating from 0.13 sees the new interface for the first time on
    /// their first launch of this version, and is asked how it feels on the next one, after
    /// having used it. A fresh install's first launch runs onboarding and does not count, so it
    /// is asked on its third launch at the earliest.
    static let minimumLaunches = 2

    /// How long the main window has to stay in front before the card opens: not the first thing
    /// on screen, and not over a window someone has just brought up to do something else.
    static let settleDelay: Duration = .seconds(4)

    struct Moment: Equatable {
        /// `AppPreferences.feedbackPromptDone`: shown before, or feedback already sent.
        var done: Bool
        /// `AppPreferences.feedbackPromptLaunches`, this launch counted.
        var launches: Int
        /// Onboarding was done when this launch started. False through the launch that runs it,
        /// even once it is finished and the main window has taken over.
        var onboardedAtLaunch: Bool
        /// This launch started in the menu bar. The window opened later in it is not asked over:
        /// that is someone reaching for something. A later launch that shows the window will be.
        var startedHidden: Bool
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
            && !moment.startedHidden
            && moment.launches >= minimumLaunches
            && moment.windowInFront
            && moment.onQuietHome
            && !moment.cardOpen
            && !moment.busy
    }

    /// The count once a launch starts. It stops at the minimum, so the preference never grows
    /// past what the decision reads.
    static func launches(after count: Int, onboardedAtLaunch: Bool) -> Int {
        onboardedAtLaunch ? min(count + 1, minimumLaunches) : count
    }

    /// Feedback sent from anywhere answers the question: the card is never opened on its own.
    @MainActor
    static func markDone() {
        AppPreferences.shared.feedbackPromptDone = true
    }
}

/// Watches the main window and opens the Feedback card in its asked mode when
/// `FeedbackPrompt.shouldAsk` says so. Never in a test process: the hosted tests and the
/// snapshot probe draw the main window too, and must not open cards or write preferences.
@MainActor
final class FeedbackPromptScheduler {
    static let shared = FeedbackPromptScheduler()

    private struct Launch {
        let onboarded: Bool
        let startedHidden: Bool
    }

    /// Nil until `recordLaunch`, and for good in a test process: nothing is asked without it.
    private var launch: Launch?
    private weak var window: NSWindow?
    private var keyObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    private init() {}

    /// From `applicationDidFinishLaunching`, with what the launch decided about the window.
    func recordLaunch(onboarded: Bool, startedHidden: Bool) {
        guard !DefaultsStore.isRunningTests else { return }
        launch = Launch(onboarded: onboarded, startedHidden: startedHidden)
        let prefs = AppPreferences.shared
        guard !prefs.feedbackPromptDone else { return }
        let count = FeedbackPrompt.launches(after: prefs.feedbackPromptLaunches, onboardedAtLaunch: onboarded)
        if count != prefs.feedbackPromptLaunches { prefs.feedbackPromptLaunches = count }
    }

    /// The main window's content joined a window, or left it (nil).
    func attach(_ window: NSWindow?) {
        guard !DefaultsStore.isRunningTests, window !== self.window else { return }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        pending?.cancel()
        self.window = window
        guard let window, !AppPreferences.shared.feedbackPromptDone else { return }
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
        prefs.feedbackPromptDone = true
        navigation.askForFeedback()
    }

    private func currentMoment() -> FeedbackPrompt.Moment? {
        guard let launch, let window else { return nil }
        let prefs = AppPreferences.shared
        let navigation = AppNavigation.shared
        let recorder = AudioRecorder.shared
        return FeedbackPrompt.Moment(
            done: prefs.feedbackPromptDone,
            launches: prefs.feedbackPromptLaunches,
            onboardedAtLaunch: launch.onboarded,
            startedHidden: launch.startedHidden,
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
