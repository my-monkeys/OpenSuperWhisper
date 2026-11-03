import Foundation
import OpenSuperWhisperCore

/// How a transcription should reach one particular app.
///
/// Typing and pasting fail in opposite places, and which one hurts is a property of the app you
/// are dictating into rather than something a single global switch can settle.
///
/// Typing posts one keyboard event per twenty characters. An app that redraws its whole input
/// area on every keystroke falls behind, and its buffer and caret drift apart: the text arrives
/// truncated at a chunk boundary, or arrives whole at a caret that has moved (#85). Pasting sends
/// one event instead of forty and is immune, but it needs the clipboard, and for someone who
/// keeps things on the clipboard on purpose that is the worse trade.
///
/// So this is a list rather than a terminal check. The two reports we have are a terminal and a
/// text editor, and we only know about those two because two people looked closely.
enum AppInsertionMode: String, Codable, CaseIterable, Identifiable {
    /// Synthetic keystrokes. Leaves the clipboard alone.
    case type
    /// A synthetic ⌘V. One event, so a heavy redraw cannot fall behind, at the cost of borrowing
    /// the clipboard when transcriptions are not kept on it.
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return "Type"
        case .paste: return "Paste"
        }
    }

    var subtitle: String {
        switch self {
        case .type: return "Synthetic keystrokes. Leaves the clipboard alone."
        case .paste: return "One ⌘V. Immune to redraw-heavy apps, but uses the clipboard."
        }
    }
}

/// One app, and how text should be put into it.
struct AppInsertionRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleIdentifier: String
    var appName: String
    var mode: AppInsertionMode

    /// Milliseconds between keystroke chunks in this app, or nil to use the global pace.
    ///
    /// Only meaningful for `.type`. It exists because paste is not the safe side for everyone:
    /// the person who reported #85 keeps the clipboard in active use, so the answer for a
    /// difficult app has to be able to be "type, but slower here" rather than only "paste".
    var typingPaceMilliseconds: Int?

    init(id: UUID = UUID(), bundleIdentifier: String = "", appName: String = "",
         mode: AppInsertionMode = .paste, typingPaceMilliseconds: Int? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.mode = mode
        self.typingPaceMilliseconds = typingPaceMilliseconds
    }
}

extension AppInsertionRule {

    /// The rule that applies to `bundleID`, or nil when nothing matches and the global settings
    /// should decide.
    ///
    /// Matched case-insensitively, because a bundle identifier typed by hand rarely comes out
    /// with the same capitalisation as the one the system reports. The first match wins, so a
    /// duplicated identifier behaves like the list reads rather than unpredictably.
    static func rule(for bundleID: String?, in rules: [AppInsertionRule],
                     disabled: [String]) -> AppInsertionRule? {
        guard let bundleID, !bundleID.isEmpty, PerAppSwitch.isOn(bundleID, disabled: disabled) else { return nil }
        return rules.first {
            !$0.bundleIdentifier.isEmpty
                && $0.bundleIdentifier.compare(bundleID, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Terminals seeded to paste on first launch (#85).
    ///
    /// A terminal redraws its whole input area on every keystroke, so typing — one event per
    /// twenty characters — loses or misplaces part of a dictation. Pasting is one event and is
    /// immune. The per-app list already carried the fix, but only for someone who found the
    /// setting and named their terminal; seeding the common ones makes a fresh install safe
    /// without that. Each is an ordinary rule the person can switch back to typing or delete, and
    /// the seed runs once, so a deletion sticks.
    ///
    /// Stable, standalone terminals only, by their release bundle identifiers. The integrated
    /// terminal of an editor (VS Code and the like) is deliberately absent: the editor is the
    /// frontmost app, and forcing its whole surface to paste would be wrong far more often than
    /// right. Someone on a terminal not listed here, or on a beta channel with another identifier,
    /// adds it themselves.
    static let bundledTerminalPresets: [AppInsertionRule] = [
        pasteRule("com.apple.Terminal", "Terminal"),
        pasteRule("com.googlecode.iterm2", "iTerm2"),
        pasteRule("com.mitchellh.ghostty", "Ghostty"),
        pasteRule("dev.warp.Warp-Stable", "Warp"),
        pasteRule("org.alacritty", "Alacritty"),
        pasteRule("net.kovidgoyal.kitty", "kitty"),
        pasteRule("com.github.wez.wezterm", "WezTerm"),
    ]

    private static func pasteRule(_ bundleIdentifier: String, _ appName: String) -> AppInsertionRule {
        AppInsertionRule(bundleIdentifier: bundleIdentifier, appName: appName, mode: .paste)
    }
}
