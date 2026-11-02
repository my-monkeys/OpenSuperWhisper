import AppKit
import SwiftUI

/// The Settings window: a native window of its own, so it opens, closes and moves independently
/// of the dashboard (#252). An NSWindow rather than a SwiftUI `Settings`/`Window` scene because
/// the status menu, the sidebar and the deep links all open it from AppKit code that has no
/// `openWindow` action, and because the app already finds and manages its windows through
/// AppKit (`AppDelegate.mainWindow`, `windowWillClose`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// What the overlay's card gave the rubric pane at the dashboard's default and minimum
    /// sizes, so every pane still fits where it did.
    static let defaultSize = CGSize(width: 1024, height: 704)
    static let minimumSize = CGSize(width: 784, height: 584)

    private let autosaveName: String?
    private let viewModel: SettingsViewModel?
    private(set) var window: NSWindow?

    /// `viewModel` and `autosaveName` are for tests: the app shares one view model with the
    /// dashboard, and a test window must not write its frame into the real preferences.
    init(autosaveName: String? = "SettingsWindow", viewModel: SettingsViewModel? = nil) {
        self.autosaveName = autosaveName
        self.viewModel = viewModel
    }

    var isOpen: Bool { window != nil }

    /// Opens the window, or brings the open one forward: there is only ever one.
    func show() {
        // Dock icon and app menu while a window is up, like the dashboard.
        NSApplication.shared.setActivationPolicy(.regular)
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = NSLocalizedString("Settings", comment: "Title of the Settings window")
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        let host = NSHostingView(rootView: SettingsWindowView(viewModel: viewModel ?? .shared))
        // The window owns its size; the pane's own minimum must not resize it behind the user.
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.center()
        // Restores the saved frame, if any, over the centred one.
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        AppNavigation.shared.settingsFocusRow = nil
        // Torn down rather than kept hidden: a hidden window would keep its panes alive, and
        // with them whatever they started on appear (the microphone level meter).
        let closing = window
        window = nil
        DispatchQueue.main.async { closing?.contentView = nil }
    }
}
