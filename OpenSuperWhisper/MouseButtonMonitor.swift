import AppKit
import Carbon
import Foundation

enum MouseButton: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case middle = "middle"
    case button4 = "button4"
    case button5 = "button5"
    case button6 = "button6"
    case button7 = "button7"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .middle: return "Button 3 (Middle)"
        case .button4: return "Button 4 (Back)"
        case .button5: return "Button 5 (Forward)"
        case .button6: return "Button 6"
        case .button7: return "Button 7"
        }
    }

    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .middle: return "🖱3"
        case .button4: return "🖱4"
        case .button5: return "🖱5"
        case .button6: return "🖱6"
        case .button7: return "🖱7"
        }
    }

    /// The `buttonNumber` reported by CGEvent's `.mouseEventButtonNumber` field.
    /// macOS numbers buttons from zero: 0 = left, 1 = right, 2 = middle, 3+ = extra
    /// (thumb / side) buttons. The user-facing names above use the common one-based
    /// convention (left = Button 1), so each case maps to `buttonNumber - 1`.
    var buttonNumber: Int64 {
        switch self {
        case .none: return -1
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        case .button6: return 5
        case .button7: return 6
        }
    }
}

class MouseButtonMonitor {
    static let shared = MouseButtonMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Buttons being watched, by their CGEvent number. More than one so a second button can
    /// mean "dictate and submit" alongside the plain record button (#50).
    private var watched: [Int64: MouseButton] = [:]
    private var pressedButton: MouseButton?

    var onButtonDown: ((MouseButton) -> Void)?
    var onButtonUp: ((MouseButton) -> Void)?

    private init() {}

    func start(mouseButton: MouseButton) {
        start(mouseButtons: [mouseButton])
    }

    func start(mouseButtons: [MouseButton]) {
        let active = mouseButtons.filter { $0 != .none }
        guard !active.isEmpty else {
            stop()
            return
        }

        stop()

        watched = Dictionary(active.map { ($0.buttonNumber, $0) }, uniquingKeysWith: { first, _ in first })
        pressedButton = nil

        let eventMask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        )

        // A default (not listen-only) tap so the bound button can be consumed and
        // used purely as a recording trigger, without also firing its normal action
        // (e.g. browser back/forward) in the focused app.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<MouseButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }

                if monitor.handleMouseEvent(type: type, event: event) {
                    // Matched the bound button — consume the event.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("MouseButtonMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("MouseButtonMonitor: Started monitoring \(active.map(\.displayName).joined(separator: ", "))")
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
        watched = [:]
        pressedButton = nil
        print("MouseButtonMonitor: Stopped")
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("MouseButtonMonitor: Re-enabled tap after timeout")
        }
    }

    /// Returns `true` when the event belongs to the bound button and should be consumed.
    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> Bool {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let button = watched[buttonNumber] else { return false }

        switch type {
        case .otherMouseDown:
            // Ignore a second button pressed mid-recording: the first one owns this take,
            // and switching intent halfway would be ambiguous.
            if pressedButton == nil {
                pressedButton = button
                DispatchQueue.main.async {
                    self.onButtonDown?(button)
                }
            }
        case .otherMouseUp:
            if pressedButton == button {
                pressedButton = nil
                DispatchQueue.main.async {
                    self.onButtonUp?(button)
                }
            }
        default:
            return false
        }
        return true
    }

    deinit {
        stop()
    }
}
