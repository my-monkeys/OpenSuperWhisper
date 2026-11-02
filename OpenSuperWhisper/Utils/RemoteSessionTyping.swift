import Carbon
import CoreGraphics
import Foundation

/// Apps that show another computer and forward what is typed to it as key presses (#255).
///
/// Neither insertion mechanism survives the trip. A synthetic ⌘V reaches the remote machine as a
/// bare V, or pastes the remote clipboard before the shared one has caught up: reported as "VV" in
/// Screen Sharing. Unicode typing fares worse, because these apps forward the key code and ignore
/// the string the event carries, and every event we post says key code 0: the remote side types
/// one "a" (or "q" in AZERTY) per chunk, which reads as random letters.
///
/// What does get through is what a person at the keyboard produces, so that is what we send: for
/// each character the key that types it in the current layout, with Shift and Option pressed and
/// released around it as real keys.
enum RemoteSession {
    static let bundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",   // Windows App, formerly Microsoft Remote Desktop
        "com.realvnc.vncviewer",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "tv.parsec.www",
    ]

    static func isRemoteSession(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// Pause after each key, so the client forwards them in order rather than in a burst it may
    /// coalesce. A per-app typing pace replaces it.
    static let defaultStrokePauseMilliseconds = 4
}

/// One key press, with the modifiers held around it.
struct KeyStroke: Equatable {
    let keyCode: CGKeyCode
    var shift = false
    var option = false
}

/// Which keys type which characters in one keyboard layout, read once from its Unicode data.
struct KeystrokeMap {
    private(set) var strokes: [Character: [KeyStroke]] = [:]

    static let returnKeyCode: CGKeyCode = 0x24
    static let tabKeyCode: CGKeyCode = 0x30

    /// The numeric keypad types the same characters as the main rows, but a Windows machine reads
    /// it through Num Lock: with Num Lock off, its 4 is a left arrow. The main rows never depend
    /// on a state we cannot see.
    private static let keypadKeyCodes: Set<CGKeyCode> = [
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52, 0x53, 0x54, 0x55,
        0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
    ]

    /// Searched in this order, so a character reachable without a modifier never gets one.
    private static let modifierCombinations: [(shift: Bool, option: Bool)] = [
        (false, false), (true, false), (false, true), (true, true),
    ]

    /// Close enough when the layout has no key for the real thing. A cleanup model writes curly
    /// quotes and dashes that a US board only reaches through Option, and some layouts not at all.
    static let substitutes: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{00AB}": "\"", "\u{00BB}": "\"", "\u{2013}": "-", "\u{2014}": "-",
        "\u{2026}": "...", "\u{00A0}": " ", "\u{202F}": " ", "\u{2009}": " ",
    ]

    init?(layoutData: CFData, keyboardType: UInt32) {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyCodes = (0..<128).map(CGKeyCode.init).filter { !Self.keypadKeyCodes.contains($0) }

        var deadKeys: [(stroke: KeyStroke, state: UInt32)] = []
        for combination in Self.modifierCombinations {
            for keyCode in keyCodes {
                let stroke = KeyStroke(keyCode: keyCode, shift: combination.shift, option: combination.option)
                var state: UInt32 = 0
                let typed = Self.translate(stroke, in: layout, keyboardType: keyboardType, deadKeyState: &state)
                if typed.isEmpty, state != 0 {
                    deadKeys.append((stroke, state))
                } else {
                    record(typed, as: [stroke])
                }
            }
        }
        // Accented letters a layout only reaches through a dead key: é is Option-E then E on a
        // US board. Searched after every single key, so a layout with an é key uses it.
        for deadKey in deadKeys {
            for combination in Self.modifierCombinations {
                for keyCode in keyCodes {
                    let stroke = KeyStroke(keyCode: keyCode, shift: combination.shift, option: combination.option)
                    var state = deadKey.state
                    let typed = Self.translate(stroke, in: layout, keyboardType: keyboardType, deadKeyState: &state)
                    record(typed, as: [deadKey.stroke, stroke])
                }
            }
        }
        strokes["\n"] = [KeyStroke(keyCode: Self.returnKeyCode)]
        strokes["\r"] = [KeyStroke(keyCode: Self.returnKeyCode)]
        strokes["\t"] = [KeyStroke(keyCode: Self.tabKeyCode)]
    }

    /// The first, and so the simplest, way found to type a character wins.
    private mutating func record(_ typed: String, as sequence: [KeyStroke]) {
        guard typed.count == 1, let character = typed.first, strokes[character] == nil,
              !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return }
        strokes[character] = sequence
    }

    private static func translate(_ stroke: KeyStroke, in layout: UnsafePointer<UCKeyboardLayout>,
                                  keyboardType: UInt32, deadKeyState: inout UInt32) -> String {
        var modifiers: UInt32 = 0
        if stroke.shift { modifiers |= UInt32((shiftKey >> 8) & 0xFF) }
        if stroke.option { modifiers |= UInt32((optionKey >> 8) & 0xFF) }
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, stroke.keyCode, UInt16(kUCKeyActionDown), modifiers,
                                    keyboardType, 0, &deadKeyState, chars.count, &length, &chars)
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// The keys that type `text`, and the characters no key of this layout can produce, even
    /// through a substitute: an emoji, or a script the layout does not cover.
    func plan(_ text: String) -> (strokes: [KeyStroke], skipped: [Character]) {
        var planned: [KeyStroke] = []
        var skipped: [Character] = []
        for character in text {
            if let sequence = strokes[character] {
                planned += sequence
            } else if let substitute = Self.substitutes[character],
                      substitute.allSatisfy({ strokes[$0] != nil }) {
                planned += substitute.flatMap { strokes[$0] ?? [] }
            } else {
                skipped.append(character)
            }
        }
        return (planned, skipped)
    }

    /// The map of the layout typing would use right now.
    static func current() -> KeystrokeMap? {
        guard let data = KeyboardLayoutProvider.currentLayoutData() else { return nil }
        return KeystrokeMap(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
    }
}
