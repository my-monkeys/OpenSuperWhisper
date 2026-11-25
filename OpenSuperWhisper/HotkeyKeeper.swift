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
///
/// The library's own bookkeeping has two blind spots, so the keeper also asks Carbon what it
/// really holds:
/// - A shortcut field left armed keeps the library's global switch off; the keeper turns it back
///   on once no capture is armed.
/// - The library can stay stuck in its "a menu is open" mode when an end-of-tracking is lost.
///   It then keeps every hot key unregistered while `isEnabled(for:)` still says true.
@MainActor
final class HotkeyKeeper {
    enum Action: Equatable {
        case none
        case resumeLibrary
        case restoreDropped
        case reregisterAll
        case recoverLost
    }

    /// What one check should do. While a shortcut field captures a combination the library is
    /// paused on purpose, so nothing is touched. A fresh registration waits for the running take
    /// to end: the trigger may be held down for push-to-talk, and taking its hot key down would
    /// lose the release that stops the recording. A dropped or lost shortcut has no registration
    /// left to lose.
    nonisolated static func action(
        reregisterPending: Bool, anyDropped: Bool, takeRunning: Bool,
        libraryPaused: Bool = false, captureArmed: Bool = false, anyLost: Bool = false
    ) -> Action {
        if captureArmed { return .none }
        if libraryPaused { return .resumeLibrary }
        if reregisterPending && !takeRunning { return .reregisterAll }
        if anyDropped { return .restoreDropped }
        return anyLost ? .recoverLost : .none
    }

    enum CombinationState: Equatable {
        case held
        case free
        case unknown
    }

    /// Whether some registration in this process holds the combination. It only ever registers a
    /// combination that nobody holds (and releases it at once), so it can never swallow a press
    /// of a working shortcut: a held one makes the registration fail instead.
    nonisolated static func probe(keyCode: UInt32, modifiers: UInt32) -> CombinationState {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: probeSignature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        switch status {
        case noErr:
            if let ref { UnregisterEventHotKey(ref) }
            return .free
        case OSStatus(eventHotKeyExistsErr):
            return .held
        default:
            return .unknown
        }
    }

    /// 'OSHK', distinct from the library's own signature.
    private nonisolated static let probeSignature: OSType = 0x4F53_484B

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
    private var reportedLost: [String] = []

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
        // A field only captures through local event monitors, which hear nothing while another
        // app is frontmost. Counting an armed field only while the app is active keeps a count
        // that a torn-down field never released from silencing the keeper for good.
        let captureArmed = ShortcutCapture.isArmed && NSApp.isActive
        let libraryPaused = !KeyboardShortcuts.isEnabled
        let lost = captureArmed || libraryPaused ? [] : lostNames(names.filter { !dropped.contains($0) })
        switch Self.action(
            reregisterPending: reregisterPending, anyDropped: !dropped.isEmpty, takeRunning: takeRunning(),
            libraryPaused: libraryPaused, captureArmed: captureArmed, anyLost: !lost.isEmpty
        ) {
        case .none:
            break
        case .resumeLibrary:
            KeyboardShortcuts.isEnabled = true
            Self.log.notice("resumed the shortcut library: it was left paused with no capture armed")
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
        case .recoverLost:
            recover(lost)
        }
    }

    private func lostNames(_ names: [KeyboardShortcuts.Name]) -> [KeyboardShortcuts.Name] {
        names.filter { name in
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
            return Self.probe(keyCode: UInt32(shortcut.carbonKeyCode), modifiers: UInt32(shortcut.carbonModifiers)) == .free
        }
    }

    /// Safe to run during a take, and from the run loop's default mode only, because of two
    /// invariants:
    /// - The timer is added in `.default` mode alone, so it never fires while a menu is tracking,
    ///   the one time the library legitimately unregisters every hot key. A combination found
    ///   free here is therefore really lost, not paused.
    /// - A lost combination has no registration, so taking it down and up again cannot lose a
    ///   key-up; and the probe only registers combinations nobody holds, so it never swallows a
    ///   press of a working shortcut.
    private func recover(_ lost: [KeyboardShortcuts.Name]) {
        // Clears the library's menu-open flag if an end-of-tracking was lost; a fresh
        // registration would otherwise be paused again at once.
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        KeyboardShortcuts.disable(lost)
        KeyboardShortcuts.enable(lost)
        let stillLost = lostNames(lost).map(\.rawValue)
        let lostList = lost.map(\.rawValue).joined(separator: ", ")
        if stillLost.isEmpty {
            reportedLost = []
            Self.log.notice("re-registered lost shortcut(s) Carbon no longer held: \(lostList, privacy: .public)")
        } else if stillLost != reportedLost {
            // Logged on change only: a failing recovery repeats every check.
            reportedLost = stillLost
            Self.log.notice("shortcut(s) lost to Carbon and not recovered: \(stillLost.joined(separator: ", "), privacy: .public)")
        }
    }
}

/// Whether a shortcut field is capturing a combination. The library is paused on purpose then,
/// which tells that pause apart from a stale one.
@MainActor
enum ShortcutCapture {
    private static var armedCount = 0

    static var isArmed: Bool { armedCount > 0 }

    static func armed() { armedCount += 1 }

    static func disarmed() { armedCount = max(0, armedCount - 1) }
}
