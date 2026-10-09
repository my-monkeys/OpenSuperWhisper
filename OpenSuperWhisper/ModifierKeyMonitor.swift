import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Modifiers being watched, by key code. More than one so a second modifier can mean
    /// "dictate and submit" alongside the plain record trigger (#50).
    private var watched: [UInt16: ModifierKey] = [:]
    private var pressedKey: ModifierKey?
    /// Chords being watched (⌘⌥ alone). They fire once, on release.
    private var watchedChords: Set<ModifierChord> = []
    private var chordDetector = ChordDetector()

    var onKeyDown: ((ModifierKey) -> Void)?
    var onKeyUp: ((ModifierKey) -> Void)?
    var onChord: ((ModifierChord) -> Void)?

    private init() {}

    func start(modifierKeys: [ModifierKey], chords: [ModifierChord] = []) {
        let active = modifierKeys.filter { $0 != .none }
        stop()
        guard !active.isEmpty || !chords.isEmpty else { return }
        watched = Dictionary(active.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })
        watchedChords = Set(chords)
        installTap(label: (active.map(\.displayName) + chords.map { $0.symbols.joined() }).joined(separator: ", "))
    }

    func start(modifierKey: ModifierKey) {
        start(modifierKeys: [modifierKey])
    }

    private func installTap(label: String) {
        pressedKey = nil
        chordDetector.reset()

        // Key presses only matter to chords: one pressed while ⌘⌥ is held makes it a shortcut.
        var eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if !watchedChords.isEmpty { eventMask |= CGEventMask(1 << CGEventType.keyDown.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    monitor.chordDetector.contaminate()
                } else {
                    monitor.handleFlagsChanged(event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ModifierKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Started monitoring for \(label)")
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
        watchedChords = []
        pressedKey = nil
        chordDetector.reset()
        print("ModifierKeyMonitor: Stopped")
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Re-enabled tap after timeout")
        }
    }
    
    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if !watchedChords.isEmpty,
           let chord = chordDetector.handleFlagsChanged(flags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))),
           watchedChords.contains(chord) {
            DispatchQueue.main.async {
                self.onChord?(chord)
            }
        }

        guard let key = watched[keyCode] else { return }

        let isPressed = flags.contains(key.cgEventFlag)

        if isPressed, pressedKey == nil {
            // A second modifier pressed mid-recording is ignored: the first owns this take.
            pressedKey = key
            DispatchQueue.main.async {
                self.onKeyDown?(key)
            }
        } else if !isPressed, pressedKey == key {
            pressedKey = nil
            DispatchQueue.main.async {
                self.onKeyUp?(key)
            }
        }
    }
    
    deinit {
        stop()
    }
}
