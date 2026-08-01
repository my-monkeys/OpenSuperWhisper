import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// The combo rule the recorder enforces, kept pure so it's unit-testable.
/// A shortcut needs at least one of ⌘ ⌥ ⌃ (⇧ alone can't be a global hotkey), except function
/// keys, which work bare (F5 as a dictation trigger).
enum RecorderCombo {
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
        kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
        kVK_F18, kVK_F19, kVK_F20,
    ]

    static func isValid(modifiers: NSEvent.ModifierFlags, keyCode: Int) -> Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
            || functionKeyCodes.contains(keyCode)
    }
}

/// What starts a recording: a key combination, a single modifier held on its own, or a mouse
/// button. One value instead of three mutually exclusive preferences with a mode picker on top.
///
/// The old shape asked the user to pick a mode first and only then record something, which meant
/// the mode could disagree with what was stored, leaving a configured key stranded behind a
/// picker (the reason `lastModifierOnlyHotkey` had to exist). Here the mode is simply whatever
/// was recorded, so the two can't drift.
enum RecordingTrigger: Equatable {
    case none
    case keyCombo(KeyboardShortcuts.Shortcut)
    case modifier(ModifierKey)
    case mouse(MouseButton)

    /// Key caps for the settings field, one per key.
    @MainActor var caps: [String] {
        switch self {
        case .none:
            return []
        case .keyCombo(let shortcut):
            let symbols = Self.modifierBadges
                .filter { shortcut.modifiers.contains($0.flag) }
                .map(\.symbol)
            let key = String(shortcut.description.drop { "⌃⌥⇧⌘".contains($0) })
            return symbols + (key.isEmpty ? [] : [key])
        case .modifier(let key):
            return [key.displayName]
        case .mouse(let button):
            return [button.displayName]
        }
    }

    static let modifierBadges: [(flag: NSEvent.ModifierFlags, symbol: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    /// Which trigger a set of stored preferences describes. Mouse wins over a single modifier,
    /// which wins over the key combination, matching how `ShortcutManager` has always resolved
    /// them, so an install upgrading into this type keeps the trigger it had.
    static func resolve(mouseRaw: String, modifierRaw: String,
                        shortcut: KeyboardShortcuts.Shortcut?) -> RecordingTrigger {
        if let button = MouseButton(rawValue: mouseRaw), button != .none {
            return .mouse(button)
        }
        if let key = ModifierKey(rawValue: modifierRaw), key != .none {
            return .modifier(key)
        }
        if let shortcut {
            return .keyCombo(shortcut)
        }
        return .none
    }
}

/// A single modifier press, recognised only when the modifier goes down and comes back up
/// without anything else happening in between.
///
/// Kept separate from the recorder view so the rule is testable: "⌥ went down, then all
/// modifiers came up, and no other key or modifier joined" is easy to get subtly wrong, and
/// getting it wrong means the field records ⌥ when the user was reaching for ⌥⇧K.
struct SingleModifierDetector {
    private(set) var candidate: ModifierKey?
    /// Set once anything else is pressed, disqualifying this press as a single-modifier one.
    private(set) var contaminated = false

    /// Feed each `flagsChanged` event. Returns a modifier when one completes a clean press.
    mutating func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ModifierKey? {
        let held = flags.intersection([.command, .option, .shift, .control, .function])
        let key = ModifierKey.allCases.first { $0 != .none && $0.keyCode == keyCode }

        if held.isEmpty {
            defer { candidate = nil; contaminated = false }
            // Everything is up: a clean press ends here.
            guard !contaminated, let candidate, candidate.keyCode == keyCode else { return nil }
            return candidate
        }

        guard let key else {
            // A modifier the enum doesn't know about; treat it as contamination rather than
            // silently ignoring it.
            contaminated = true
            return nil
        }

        if candidate == nil {
            candidate = key
        } else if candidate != key {
            // A second modifier joined, so this is heading for a combination.
            contaminated = true
        }
        return nil
    }

    /// Any non-modifier key press disqualifies the current press.
    mutating func contaminate() {
        contaminated = true
    }

    mutating func reset() {
        candidate = nil
        contaminated = false
    }
}
