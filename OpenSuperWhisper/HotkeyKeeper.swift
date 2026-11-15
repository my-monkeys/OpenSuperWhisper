import AppKit
import Carbon
import KeyboardShortcuts
import os

/// Keeps the key-combination shortcuts registered for the life of the app.
///
/// Two things could leave ⌥` dead until a relaunch:
/// - KeyboardShortcuts takes every hot key down while one of the app's menus is open and puts
///   it back once the menu closes. If putting one back fails a single time, the library drops
///   that shortcut for good, and the app only rebinds on a settings change.
/// - macOS holds back shortcuts made of Option and one key while secure input is on: a
///   password field, a password manager, Secure Keyboard Entry in a terminal.
///
/// So the keeper restores any shortcut the library dropped, and once secure input ends, or the
/// Mac wakes or unlocks, it registers them all afresh.
@MainActor
final class HotkeyKeeper {
    enum Action: Equatable {
        case none
        case restoreDropped
        case reregisterAll
    }

    /// What one check should do. A fresh registration waits for the running take to end: the
    /// trigger may be held down for push-to-talk, and taking its hot key down would lose the
    /// release that stops the recording. A dropped shortcut has no registration left to lose.
    nonisolated static func action(reregisterPending: Bool, anyDropped: Bool, takeRunning: Bool) -> Action {
        if reregisterPending && !takeRunning { return .reregisterAll }
        return anyDropped ? .restoreDropped : .none
    }

    nonisolated static func secureInputEnded(was: Bool, isNow: Bool) -> Bool {
        was && !isNow
    }

    /// Short enough that a dropped shortcut is back before the next try, cheap enough to run
    /// for the life of the app: a check reads a few stored shortcuts and one system flag.
    static let checkInterval: TimeInterval = 2

    private static let log = Logger(subsystem: Diag.subsystem, category: "hotkey")

    private let liveNames: () -> [KeyboardShortcuts.Name]
    private let takeRunning: () -> Bool
    private var timer: Timer?
    private var secureInputWasOn = IsSecureEventInputEnabled()
    private var reregisterPending = false

    /// `liveNames` are the shortcuts that should be listening right now: the bound trigger slots
    /// and the optional shortcuts the user set.
    init(liveNames: @escaping () -> [KeyboardShortcuts.Name], takeRunning: @escaping () -> Bool) {
        self.liveNames = liveNames
        self.takeRunning = takeRunning
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(workspace, NSWorkspace.screensDidWakeNotification)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"))

        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = Self.checkInterval / 4
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        // The keeper lives as long as the app, so the observers are never removed.
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reregisterPending = true }
        }
    }

    private func check() {
        let secureInputIsOn = IsSecureEventInputEnabled()
        if Self.secureInputEnded(was: secureInputWasOn, isNow: secureInputIsOn) {
            reregisterPending = true
        }
        secureInputWasOn = secureInputIsOn

        let names = liveNames()
        let dropped = names.filter { !KeyboardShortcuts.isEnabled(for: $0) }
        switch Self.action(reregisterPending: reregisterPending, anyDropped: !dropped.isEmpty, takeRunning: takeRunning()) {
        case .none:
            break
        case .restoreDropped:
            KeyboardShortcuts.enable(dropped)
            // Logged only when it worked: a combination another app holds fails on every
            // check, and that would fill the log every two seconds.
            let restored = dropped.filter { KeyboardShortcuts.isEnabled(for: $0) }
            if !restored.isEmpty {
                Self.log.notice("restored dropped shortcut(s): \(restored.map(\.rawValue).joined(separator: ", "), privacy: .public)")
            }
        case .reregisterAll:
            reregisterPending = false
            guard !names.isEmpty else { return }
            Self.log.notice("registered \(names.count) shortcut(s) afresh after secure input, wake or unlock")
            KeyboardShortcuts.disable(names)
            KeyboardShortcuts.enable(names)
        }
    }
}
