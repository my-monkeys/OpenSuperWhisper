import AppKit
import Carbon
import Foundation

/// Watches for the "latch" key (Space) via a keyDown event tap.
///
/// Used to turn a push-to-talk recording into a hands-free (latched) one: while a recording is
/// active, pressing Space keeps it going even after the trigger key (e.g. Fn) is released. The
/// Space keystroke is swallowed so it does not leak a literal space into the focused app.
///
/// The tap's lifetime IS the recording's lifetime: `ShortcutManager` starts it when a recording
/// starts and stops it when the recording ends. Between recordings — almost all of the time —
/// no tap exists, so an idle OpenSuperWhisper is not in the path of anyone's keystrokes. That
/// scoping is also what keeps this class free of cross-thread state: while the tap exists, every
/// Space is ours to consume, so the callback never has to ask the main thread whether to act.
final class LatchKeyMonitor {
    static let shared = LatchKeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let latchKeyCode = UInt16(kVK_Space)

    /// Fires (on the main queue) when the latch key is pressed while the tap is up.
    var onLatchKeyDown: (() -> Void)?

    private init() {}

    /// Idempotent; called from the main thread when a recording starts (and the latch
    /// preference is on).
    func start() {
        guard eventTap == nil else { return }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<LatchKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if keyCode == monitor.latchKeyCode {
                    DispatchQueue.main.async { monitor.onLatchKeyDown?() }
                    // Swallow the Space so it is not typed into the focused app.
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("LatchKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Idempotent; called from the main thread when the recording ends (any path) or the latch
    /// preference is switched off.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("LatchKeyMonitor: Re-enabled tap after timeout")
        }
    }

    deinit {
        stop()
    }
}
