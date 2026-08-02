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
enum RecordingTrigger: Equatable, Codable {
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

    /// Every trigger the stored preferences describe. More than one can be live at a time — a
    /// thumb button at the desk and a shortcut on the move — so this returns all of them rather
    /// than picking a winner (#48).
    static func resolveAll(mouseRaw: String, modifierRaw: String,
                           shortcut: KeyboardShortcuts.Shortcut?) -> [RecordingTrigger] {
        var triggers: [RecordingTrigger] = []
        if let shortcut { triggers.append(.keyCombo(shortcut)) }
        if let key = ModifierKey(rawValue: modifierRaw), key != .none { triggers.append(.modifier(key)) }
        if let button = MouseButton(rawValue: mouseRaw), button != .none { triggers.append(.mouse(button)) }
        return triggers
    }

    /// The single trigger these preferences describe, for the fields that only ever hold one
    /// (cancel, submit, paste-last). Mouse wins over a modifier, which wins over the shortcut.
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

    /// Two triggers of the same kind can't coexist: there is one shortcut slot, one modifier
    /// preference and one mouse-button preference, so recording a new one of a kind replaces it.
    var kind: Kind {
        switch self {
        case .none: return .keyCombo
        case .keyCombo: return .keyCombo
        case .modifier: return .modifier
        case .mouse: return .mouse
        }
    }

    enum Kind { case keyCombo, modifier, mouse }
}

/// The recording triggers, in the order they were added. Any number of each kind: the old shape
/// held one slot per kind (one shortcut, one modifier preference, one mouse-button preference),
/// which capped it at three however the UI was drawn (#48).
struct RecordingTriggerSet: Equatable, Codable {
    var triggers: [RecordingTrigger]

    static let empty = RecordingTriggerSet(triggers: [])

    var modifiers: [ModifierKey] {
        triggers.compactMap { if case .modifier(let key) = $0 { return key } else { return nil } }
    }

    var mouseButtons: [MouseButton] {
        triggers.compactMap { if case .mouse(let button) = $0 { return button } else { return nil } }
    }

    var keyCombos: [KeyboardShortcuts.Shortcut] {
        triggers.compactMap { if case .keyCombo(let combo) = $0 { return combo } else { return nil } }
    }

    /// Appends unless an identical trigger is already there — recording the same key twice
    /// should be a no-op, not a duplicate row that fires once.
    mutating func add(_ trigger: RecordingTrigger) {
        guard trigger != .none, !triggers.contains(trigger) else { return }
        triggers.append(trigger)
    }

    mutating func remove(_ trigger: RecordingTrigger) {
        triggers.removeAll { $0 == trigger }
    }

    /// The modifier and mouse button bound to a different action, if either collides with this
    /// list. One key can only mean one thing: bound twice, whicheverthe router checks first
    /// wins and the other binding looks broken with nothing on screen to explain it.
    func conflicts(modifier: ModifierKey, mouse: MouseButton) -> (modifier: Bool, mouse: Bool) {
        (modifier != .none && modifiers.contains(modifier),
         mouse != .none && mouseButtons.contains(mouse))
    }

    // MARK: - Persistence

    static func load(from json: String) -> RecordingTriggerSet {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RecordingTriggerSet.self, from: data)
        else { return .empty }
        return decoded
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Carries the three single-slot preferences into the list, so an existing install keeps
    /// the trigger it had.
    static func migrated(mouseRaw: String, modifierRaw: String,
                         shortcut: KeyboardShortcuts.Shortcut?) -> RecordingTriggerSet {
        var set = RecordingTriggerSet.empty
        for trigger in RecordingTrigger.resolveAll(mouseRaw: mouseRaw, modifierRaw: modifierRaw,
                                                   shortcut: shortcut) {
            set.add(trigger)
        }
        return set
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
