import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()

    /// The indicator window is sized manually (see `resizeToContent`) — NEVER via NSHostingView's
    /// `.preferredContentSize` auto-resize. That auto-resize animates the window frame on macOS 26
    /// (`NSHostingView.updateAnimatedWindowSize`) and recurses into layout until the main-thread
    /// stack overflows (#11/#15/#19). Must stay empty; `IndicatorLayoutRecursionTests` guards it.
    nonisolated static let hostingSizingOptions: NSHostingSizingOptions = []

    var window: NSWindow?
    var viewModel: IndicatorViewModel?

    // The window auto-sizes to its content (so the live caption pill grows with the text).
    // We keep the bottom edge anchored near the caret so it grows upward, not over the caret.
    private var anchorBottomY: CGFloat = 0
    private var anchorCenterX: CGFloat = 0
    // Notch mode anchors the *top* edge instead (the pill hangs from the screen top, growing down).
    private var anchorFromTop = false
    private var anchorTopY: CGFloat = 0
    private var resizeObserver: NSObjectProtocol?
    private var drainObserver: AnyCancellable?

    private init() {}
    
    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {
        
        KeyboardShortcuts.enable(.escape)

        // A recording started while the previous one was still transcribing: the bubble belongs
        // to the new take now, so stop waiting to hide it on the old one's behalf.
        drainObserver?.cancel()
        drainObserver = nil

        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel

        // Measured per show, and measured *first*. The bubble follows the caret, so which screen
        // it lands on changes and only one of them may have hardware in the way. It has to be on
        // the view model before the view is built: the first layout pass decides the shape the
        // entrance animates out of, and a pass that ran before the measurement arrived armed the
        // wrong one, which is what made the bubble visibly rise before settling.
        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
        newViewModel.physicalNotch = targetScreen.flatMap { NotchMetrics.physicalNotch(for: $0) }

        if window == nil {
            // Create window if it doesn't exist - using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            // Fully click-through by default, matching the my-monkeys baseline: the
            // indicator never intercepts clicks meant for the app underneath. When the
            // opt-in on-bubble Stop/Cancel buttons are enabled, this is flipped per
            // show() below so they're tappable.
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Belt-and-suspenders: the window is sized manually + non-animated via
            // `resizeToContent` (#19), and this also stops AppKit from animating the frame on
            // its own. Size changes should snap, never animate (macOS 26 recursion guard).
            panel.animationBehavior = .none
            // Grabbing the bubble anywhere that is not a button moves it. Only reachable when the
            // panel accepts mouse events at all, which is the opt-in below.
            panel.isMovableByWindowBackground = true

            self.window = panel
            observeDrag(of: panel)
        }
        
        // Host the SwiftUI content and size the window to it *ourselves* (see `resizeToContent`).
        // We deliberately do NOT use `sizingOptions = [.preferredContentSize]`: that auto-resize
        // runs animated on macOS 26 (NSHostingView.updateAnimatedWindowSize) and recurses into
        // layout until the main-thread stack overflows — the #11/#15/#19 crash.
        let hostingController = NSHostingController(
            rootView: IndicatorWindow(viewModel: newViewModel) { [weak self] size in
                self?.resizeToContent(size)
            }
            // Read once per presentation rather than observed: the bubble is short-lived, and a
            // size change mid-recording would resize the window under the user (#80).
            .environment(\.appTextScale, AppPreferences.shared.textScale)
        )
        hostingController.sizingOptions = Self.hostingSizingOptions
        window?.contentViewController = hostingController
        // Assigning a hosting controller with empty sizingOptions as the contentViewController
        // can leave the panel at 0×0 (seen on macOS 26; users reported it on macOS 15.7.x too):
        // SwiftUI then lays out in a 0×0 canvas, the content preference reports 0×0, and
        // `resizeToContent`'s `> 1` guard discards it — so the window stays 0×0 and the indicator
        // never appears in ANY position mode (#indicator-invisible). Seed a non-zero canvas
        // (non-animated, so no NSHostingView recursion-crash risk) so SwiftUI can lay out and
        // size the window.
        //
        // Around a real notch that canvas is the finished size rather than a placeholder. The
        // placeholder was 380×120 against a bubble 38pt tall, and NSHostingView centres a smaller
        // content in its window: the pill was drawn a good 40pt below a window pinned to the top
        // of the screen, then jumped up when the measured size came back. That is the climb the
        // entrance was blamed for.
        window?.setContentSize(seedSize(for: newViewModel.physicalNotch))

        // Accept clicks only when an on-bubble button is enabled (so it's tappable);
        // otherwise stay fully click-through (baseline). Re-evaluated each show() so
        // toggling the setting takes effect on the next recording.
        window?.ignoresMouseEvents = !Self.needsMouseEvents(
            position: AppPreferences.shared.indicatorPosition,
            showsStop: AppPreferences.shared.showStopButtonOnIndicator,
            showsCancel: AppPreferences.shared.showCancelButtonOnIndicator)

        if let window = window, let screen = targetScreen {
            let screenFrame = screen.frame

            anchorFromTop = false
            switch AppPreferences.shared.indicatorPosition {
            case "notch":
                // Hang from the very top-center, growing downward — sitting in/around the notch
                // on notched Macs, or as a faux-notch pill on Macs without one.
                anchorFromTop = true
                anchorCenterX = screenFrame.midX
                anchorTopY = screenFrame.maxY
            case "top":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.maxY - 140
            case "center":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.midY
            case "bottom":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.minY + 120
            case "custom":
                // Wherever it was last dropped. Falls back to the centre of the screen if the
                // mode is set but nothing has been dragged yet, so it is never off-screen.
                let dropped = AppPreferences.shared.indicatorCustomAnchor
                anchorCenterX = dropped?.x ?? screenFrame.midX
                anchorBottomY = dropped?.y ?? screenFrame.midY
            default: // "cursor": sit just above the caret, falling back to a band near the top
                if let point = point {
                    anchorBottomY = point.y + 20
                    anchorCenterX = point.x
                } else {
                    anchorBottomY = screenFrame.maxY - 260
                    anchorCenterX = screenFrame.midX
                }
            }

            reposition(window: window, screen: screen)

            // Keep the bottom edge anchored as the content (and window) grows upward.
            if resizeObserver == nil {
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window, let screen = window.screen ?? NSScreen.main else { return }
                    self.reposition(window: window, screen: screen)
                }
            }
        }

        // The indicator must draw over the menu bar AND over apps in a native full-screen space
        // (dictating into a full-screen app). `.fullScreenAuxiliary` + `.canJoinAllSpaces` let the
        // panel join the full-screen space, but that's not enough on its own: a `.statusBar`/
        // `.mainMenu`-level window (25) is occluded by the full-screen app's system-elevated window,
        // so the pill goes invisible there (#notch-fullscreen). `.screenSaver` (1000) is the level
        // dedicated overlay/notch apps (Lunar, boring.notch) use to sit above full-screen content;
        // it's also comfortably above the menu bar, so the notch pill still clears it.
        window?.level = .screenSaver
        window?.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]

        window?.orderFront(nil)
        return newViewModel
    }

    /// The canvas the window starts on, before SwiftUI has measured anything.
    ///
    /// Around a real notch this is the answer, not a guess: `NotchGeometry` is the single place
    /// the width is worked out, and the view builds its bubble from the very same call. Anywhere
    /// else it stays a roomy placeholder, since the size there depends on text nobody has laid
    /// out yet and `resizeToContent` settles it a frame later.
    private func seedSize(for cutout: CGSize?) -> NSSize {
        guard AppPreferences.shared.indicatorPosition == "notch",
              let geometry = NotchGeometry.measure(
                cutout: cutout,
                layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout),
                textScale: CGFloat(TextScale.clamped(AppPreferences.shared.textScale)),
                topRadius: CGFloat(NotchTuning.shared.topRadius),
                bottomRadius: CGFloat(NotchTuning.shared.bottomRadius))
        else { return NSSize(width: 380, height: 120) }

        return NSSize(width: geometry.width, height: geometry.bandHeight)
    }

    /// Sizes the indicator window to its SwiftUI content, *non-animated*. This replaces
    /// NSHostingView's `.preferredContentSize` auto-resize, whose animated variant recurses into
    /// layout and overflows the main-thread stack on macOS 26 (#11/#15/#19). `setContentSize`
    /// snaps in a single pass, so no SwiftUI animation can ever drive a window resize.
    private func resizeToContent(_ size: CGSize) {
        guard let window, size.width > 1, size.height > 1 else { return }
        let newSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        let current = window.contentRect(forFrameRect: window.frame).size
        if abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5 {
            window.setContentSize(newSize)
        }
        if let screen = window.screen ?? NSScreen.main {
            reposition(window: window, screen: screen)
        }
    }

    /// Whether the bubble should accept clicks instead of letting them through to the app below.
    ///
    /// Click-through is the baseline: the indicator never intercepts a click meant for what you
    /// are dictating into. Two things override it. On-bubble buttons, which have to be tappable to
    /// exist at all. And the draggable position, because a bubble you are meant to grab has to be
    /// grabbable, which is the trade you accept by choosing that mode and no other.
    nonisolated static func needsMouseEvents(position: String, showsStop: Bool,
                                             showsCancel: Bool) -> Bool {
        showsStop || showsCancel || position == "custom"
    }

    /// The origin `reposition` last asked for, so the window's own move notification is not
    /// mistaken for the user dragging the bubble.
    ///
    /// Compared by value rather than guarded with a flag, because the move notification is not
    /// guaranteed to arrive inside the `setFrameOrigin` call that caused it.
    private var lastPlacedOrigin: NSPoint?

    private var dragObserver: NSObjectProtocol?

    /// Remembers where the bubble is dropped, and switches the position mode to match.
    ///
    /// Dragging something is a plainer statement of intent than picking from a menu, so a drop
    /// wins: whatever preset was selected becomes "custom", and the bubble stays where it was put,
    /// including across restarts.
    private func observeDrag(of panel: NSWindow) {
        dragObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            let origin = panel.frame.origin
            if let placed = lastPlacedOrigin,
               abs(placed.x - origin.x) < 1, abs(placed.y - origin.y) < 1 { return }

            let anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
            AppPreferences.shared.indicatorCustomAnchor = anchor
            AppPreferences.shared.indicatorPosition = "custom"
            anchorFromTop = false
            anchorCenterX = anchor.x
            anchorBottomY = anchor.y
        }
    }

    private func reposition(window: NSWindow, screen: NSScreen) {
        let w = window.frame.width
        let h = window.frame.height
        let screenFrame = screen.frame
        let x = max(screenFrame.minX, min(anchorCenterX - w / 2, screenFrame.maxX - w))
        // Notch mode pins the top edge (grows down); everything else pins the bottom (grows up).
        let y = anchorFromTop
            ? max(screenFrame.minY, anchorTopY - h)
            : max(screenFrame.minY, min(anchorBottomY, screenFrame.maxY - h))
        let origin = NSPoint(x: x, y: y)
        lastPlacedOrigin = origin
        window.setFrameOrigin(origin)
    }

    /// Briefly shows the indicator at the configured position (without recording) so the user
    /// can see where it will appear. Used by the position picker's "Preview" button.
    func preview() {
        guard viewModel == nil else { return } // don't interfere with a live recording
        let vm = show(nearPoint: FocusUtils.getCurrentCursorPosition())
        vm.state = .recording
        vm.isBlinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.hide()
        }
    }

    /// Briefly show a status message (error / info) WITHOUT recording. Used by the background
    /// `DictationPipeline` to surface a failure, "no speech", or the "copied — press ⌘V" notice now
    /// that transcription no longer runs in a live indicator. Skipped while a recording is in
    /// progress so it never interrupts the live recording bubble. The message auto-hides via the
    /// view model's own timer (showError/showInfo). (parallel-recording #3)
    func flash(_ state: RecordingState) {
        if let current = viewModel, current.state == .recording || current.state == .connecting {
            return
        }
        let vm = show(nearPoint: FocusUtils.getCurrentCursorPosition())
        switch state {
        case .error(let message): vm.showError(message)
        case .info(let message): vm.showInfo(message)
        default: vm.showBusyMessage()
        }
    }

    func stopRecording() {
        viewModel?.startDecoding()
    }

    /// Reflect the hands-free latch in the bubble. No-op when nothing is showing.
    func setLatched(_ latched: Bool) {
        viewModel?.isLatched = latched
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    /// An Esc-cancel request. Returns `true` when the recording was actually
    /// discarded; `false` when a long recording is now waiting for a confirming
    /// second Esc (see `IndicatorViewModel.handleCancelRequest`).
    @discardableResult
    func requestCancel() -> Bool {
        guard let viewModel else { return false }
        guard viewModel.handleCancelRequest() else { return false }
        stopForce()
        return true
    }

    func hide() {
        KeyboardShortcuts.disable(.escape)
        drainObserver?.cancel()
        drainObserver = nil

        Task {
            guard let viewModel = self.viewModel else { return }

            await viewModel.hideWithAnimation()
            viewModel.cleanup()

            // A new recording may have started during the hide animation (rapid re-record now
            // that recording is decoupled from transcription). If show() has since installed a
            // different view model, this teardown belongs to the *previous* recording — don't
            // clear the window/content out from under the new one, or reset the hotkey state.
            // (parallel-recording)
            guard self.viewModel === viewModel else { return }

            self.window?.contentView = nil
            self.window?.orderOut(nil)
            self.viewModel = nil

            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        // The clip has gone to the background pipeline and the bubble is free for the next
        // recording. It used to vanish here, which left nothing on screen between the moment
        // you stop talking and the moment the text lands: on a slow model that reads as the
        // dictation having been dropped. It stays instead, showing that work is still running.
        guard DictationPipeline.shared.isProcessing else {
            hide()
            return
        }

        viewModel?.state = .decoding
        watchPipelineDrain()
    }

    /// Hides the bubble once the queue empties.
    ///
    /// Nothing is torn down if a new recording arrives first: `show()` hands out a fresh view
    /// model, and this only ever hides while the one it is watching is still the current one and
    /// still decoding.
    private func watchPipelineDrain() {
        drainObserver?.cancel()
        let watched = viewModel
        drainObserver = DictationPipeline.shared.$isProcessing
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.viewModel === watched, self.viewModel?.state == .decoding
                    else { return }
                    self.hide()
                }
            }
    }
}
