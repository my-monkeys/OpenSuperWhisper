import AppKit
import KeyboardShortcuts
import SwiftUI
import WhisperCore

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

    private init() {}
    
    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {
        
        KeyboardShortcuts.enable(.escape)
        
        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
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

            self.window = panel
        }
        
        // Host the SwiftUI content and size the window to it *ourselves* (see `resizeToContent`).
        // We deliberately do NOT use `sizingOptions = [.preferredContentSize]`: that auto-resize
        // runs animated on macOS 26 (NSHostingView.updateAnimatedWindowSize) and recurses into
        // layout until the main-thread stack overflows — the #11/#15/#19 crash.
        let hostingController = NSHostingController(
            rootView: IndicatorWindow(viewModel: newViewModel) { [weak self] size in
                self?.resizeToContent(size)
            }
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
        window?.setContentSize(NSSize(width: 380, height: 120))

        // Accept clicks only when an on-bubble button is enabled (so it's tappable);
        // otherwise stay fully click-through (baseline). Re-evaluated each show() so
        // toggling the setting takes effect on the next recording.
        window?.ignoresMouseEvents = !(AppPreferences.shared.showStopButtonOnIndicator
            || AppPreferences.shared.showCancelButtonOnIndicator)

        // Position window - use the screen containing the point, or main screen as fallback
        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
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

    private func reposition(window: NSWindow, screen: NSScreen) {
        let w = window.frame.width
        let h = window.frame.height
        let screenFrame = screen.frame
        let x = max(screenFrame.minX, min(anchorCenterX - w / 2, screenFrame.maxX - w))
        // Notch mode pins the top edge (grows down); everything else pins the bottom (grows up).
        let y = anchorFromTop
            ? max(screenFrame.minY, anchorTopY - h)
            : max(screenFrame.minY, min(anchorBottomY, screenFrame.maxY - h))
        window.setFrameOrigin(NSPoint(x: x, y: y))
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
        hide()
    }
}
