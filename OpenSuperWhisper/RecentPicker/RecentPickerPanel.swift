import AppKit
import OpenSuperWhisperCore
import SwiftUI

/// Opens a small panel next to the text cursor listing the latest dictations; a digit key
/// inserts one into the app the user was typing in.
///
/// The panel is non-activating: it becomes the key window, so it gets the key presses, without
/// OpenSuperWhisper ever becoming the active app. The app being typed in stays frontmost, which
/// is where `PasteLastTranscript.insert` sends its ⌘V.
@MainActor
final class RecentPickerController {
    static let shared = RecentPickerController()

    /// Time for the previous app's window to take key status back after the panel leaves. Its
    /// window stopped being key when the panel became key, and a ⌘V sent before it is key again
    /// goes to nobody.
    private static let keyHandoffDelay: UInt64 = 120_000_000

    private let model = RecentPickerModel()
    private var panel: RecentPickerPanel?

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    /// The shortcut's action: opens the panel, or closes it when it is already open.
    func toggle() async {
        if isVisible { close(); return }
        // Half a long prompt is in and the rest on its way (#165): a paste now would land in
        // the middle of it, as `PasteLastTranscript.run` also refuses.
        guard !TranscriptInserter.pastingInPieces else {
            Diag.mark("recent-picker: ignored while a paste in pieces goes in")
            return
        }
        // History off, or unreadable, shows the empty line rather than an error: both mean
        // there is nothing to pick.
        let recordings = (try? await RecordingStore.shared.fetchRecordings(
            limit: RecentPicker.scanDepth, offset: 0)) ?? []
        // A second press while the read was running has opened the panel already.
        guard !isVisible else { return }
        model.rows = RecentPicker.rows(from: recordings)
        model.highlighted = 0
        show()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            panel.setContentSize(host.fittingSize)
        }
        panel.setFrame(placedFrame(size: panel.frame.size), display: false)
        // Never NSApp.activate: that would take the keyboard from the app being typed in.
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }

    private func makePanel() -> RecentPickerPanel {
        let panel = RecentPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: RecentPickerView.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The card draws its own shadow, see AgentPanel.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.onKey = { [weak self] keyCode in self?.handle(keyCode: keyCode) ?? false }
        // A click elsewhere takes key status away: the picker has nothing left to say.
        panel.onResignKey = { [weak self] in self?.close() }
        panel.contentView = FirstClickHostingView(
            rootView: RecentPickerRoot(model: model) { [weak self] row in self?.insert(row) })
        return panel
    }

    private func handle(keyCode: UInt16) -> Bool {
        guard let action = RecentPicker.action(forKeyCode: keyCode) else { return false }
        switch action {
        case .close:
            close()
        case .moveHighlight(let step):
            model.highlighted = RecentPicker.highlight(after: model.highlighted, by: step,
                                                       rowCount: model.rows.count)
        case .insertHighlighted:
            if model.rows.indices.contains(model.highlighted) { insert(model.rows[model.highlighted]) }
        case .insert(let number):
            if let row = model.rows.first(where: { $0.number == number }) { insert(row) }
        }
        return true
    }

    private func insert(_ row: RecentPicker.Row) {
        close()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.keyHandoffDelay)
            await PasteLastTranscript.insert(row.text)
        }
    }

    // MARK: Placement

    /// Next to the caret when accessibility can place it, otherwise next to the mouse.
    private func placedFrame(size: CGSize) -> NSRect {
        let anchor: CGRect
        if let caret = FocusUtils.getCaretRect(),
           let primary = NSScreen.screens.first {
            anchor = RecentPicker.cocoaRect(fromAX: caret, primaryScreenMaxY: primary.frame.maxY)
        } else {
            let mouse = FocusUtils.getCurrentCursorPosition()
            anchor = CGRect(origin: mouse, size: .zero)
        }
        let screen = FocusUtils.screenContaining(point: anchor.origin) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The card sits inside a transparent margin for its shadow: measure the gap and the
        // screen edges from the card, not from the window.
        let room = RecentPickerView.shadowRoom
        let card = RecentPicker.frame(
            size: CGSize(width: size.width - 2 * room, height: size.height - 2 * room),
            anchor: anchor, visible: visible)
        return card.insetBy(dx: -room, dy: -room)
    }
}

/// Borderless panels refuse key status by default, which would leave the picker without keys.
final class RecentPickerPanel: NSPanel {
    var onKey: ((UInt16) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Caught before the hosting view sees them: its buttons would otherwise take Return and
    /// the arrows for focus navigation.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event.keyCode) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
