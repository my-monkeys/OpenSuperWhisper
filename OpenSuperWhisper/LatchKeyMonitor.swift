import AppKit
import Carbon
import Foundation

/// Watches for the "latch" key (Space) via a keyDown event tap.
///
/// Used to turn a push-to-talk recording into a hands-free (latched) one:
/// while a recording is active, pressing Space keeps it going even after the
/// trigger key (e.g. Fn) is released. The Space keystroke is swallowed while
/// recording so it does not leak a literal space into the focused app.
final class LatchKeyMonitor {
    static let shared = LatchKeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// kVK_Space
    private let latchKeyCode: UInt16 = 49

    /// Fires (on the main queue) when the latch key is pressed while a
    /// recording is active.
    var onLatchKeyDown: (() -> Void)?

    /// Queried synchronously on the tap thread. Return `true` when a recording
    /// is active so the Space event is consumed; otherwise it passes through
    /// untouched (normal typing keeps working).
    var shouldConsume: (() -> Bool)?

    private init() {}

    func start() {
        stop()

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
                if keyCode == monitor.latchKeyCode, monitor.shouldConsume?() == true {
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("LatchKeyMonitor: Started")
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
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
