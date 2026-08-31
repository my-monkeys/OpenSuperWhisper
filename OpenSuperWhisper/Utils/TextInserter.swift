import AppKit
import CoreGraphics
import Foundation

/// Inserts text into the frontmost app by synthesizing Unicode keyboard input.
/// Never touches the pasteboard, so there is no clipboard race or restore.
enum TextInserter {

    /// Splits `text` into UTF-16 unit groups of at most `maxUnits` units each,
    /// never splitting a surrogate pair (a group may be one unit longer when it
    /// has to absorb a trailing low surrogate). Concatenating the groups
    /// reproduces `text` exactly.
    static func chunks(of text: String, maxUnits: Int = 20) -> [[UniChar]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        var result: [[UniChar]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            // A high surrogate must keep its following low surrogate in the same
            // chunk, or the emoji is torn in half.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end += 1
            }
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }

    /// Pause between chunks, so the receiving app gets a chance to process each one.
    ///
    /// Unpaced, a 400-character dictation is ~40 key events posted inside a millisecond. An app
    /// that re-renders its whole input area per keystroke falls behind, and its buffer and caret
    /// drift apart: reported as existing text duplicated two or three times with the new speech
    /// wedged inside, in a terminal TUI, and it got likelier the fuller the input box already was
    /// (#85). Paste mode was unaffected, which is one event instead of forty.
    static let chunkPauseMicroseconds: useconds_t = 2_000

    /// Ceiling on the delay this adds in total. Typing runs on the main thread, and it has to:
    /// the caller presses Return after it returns, so going async would race the submit key
    /// against the text. A very long dictation therefore trades pacing for responsiveness rather
    /// than freezing the app.
    static let maxTotalPauseMicroseconds: useconds_t = 500_000

    /// How long to wait between chunks for a text of `chunkCount` chunks.
    static func chunkPause(forChunkCount chunkCount: Int) -> useconds_t {
        guard chunkCount > 1 else { return 0 }
        let gaps = useconds_t(chunkCount - 1)
        return min(chunkPauseMicroseconds, maxTotalPauseMicroseconds / gaps)
    }

    /// Types `text` into the focused app as Unicode keyboard events. Each chunk
    /// is sent as one key-down/key-up pair carrying the Unicode string; modifier
    /// flags are cleared so a still-held hotkey can't combine with the input.

    /// One line describing an insertion, for diagnosing corruption that only happens in the wild.
    ///
    /// Asked for on #85 by the person reporting it, and it is the right ask: the fault fires about
    /// twice in twelve hours, so turning a pacing dial by feel costs days per setting and invites
    /// reading noise as signal. The numbers at the moment it breaks answer directly what the pause
    /// should scale with. Written as one flat line so it can be pasted into an issue.
    ///
    /// `targetLength` nil is itself a finding rather than a gap: an app that will not say how much
    /// it is holding is an app where pacing derived from that number cannot work, and the report
    /// came from an Electron terminal.
    static func insertionLogLine(app: String, targetLength: Int?, caret: Int?,
                                 payload: Int, chunks: Int, pause: useconds_t) -> String {
        let gaps = max(chunks - 1, 0)
        let target = targetLength.map(String.init) ?? "unavailable"
        let caretText = caret.map(String.init) ?? "unavailable"
        return "insert app=\(app) target=\(target) caret=\(caretText) payload=\(payload) "
            + "chunks=\(chunks) pause=\(pause)us/gap total=\(UInt(pause) * UInt(gaps))us"
    }

    /// Reads the target's state and logs the line. Skipped entirely when diagnostics are off: the
    /// accessibility read costs up to 32ms, and the insertion path should not pay that to log
    /// nothing.
    private static func logInsertion(payload: String, chunks: Int, pause: useconds_t) {
        guard Diag.isEnabled else { return }
        let metrics = FocusUtils.focusedTextMetrics()
        Diag.mark(insertionLogLine(
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            targetLength: metrics?.length,
            caret: metrics?.caret,
            payload: payload.count,
            chunks: chunks,
            pause: pause))
    }

    static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let allChunks = chunks(of: text)
        let pause = chunkPause(forChunkCount: allChunks.count)
        logInsertion(payload: text, chunks: allChunks.count, pause: pause)

        for (index, chunk) in allChunks.enumerated() {
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            var units = chunk
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            if pause > 0 && index < allChunks.count - 1 {
                usleep(pause)
            }
        }
    }

    /// Pastes the current clipboard into the focused app via a synthetic ⌘V. Universal — works in
    /// apps that ignore synthetic Unicode typing (Messages, Electron, …). The caller must have put
    /// the text on the clipboard first.
    static func paste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cmdKey: CGKeyCode = 0x37 // kVK_Command
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else { return }
        // Post the real ⌘ key around V (not just the .maskCommand flag) so apps that read the
        // physical modifier state — not only the event flags — still register the paste.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }

    /// Presses Return in the focused app — used by the "press enter" voice command to submit a
    /// message or prompt after the dictated text has been inserted. Modifier flags are cleared so a
    /// still-held hotkey can't turn it into a shortcut (⌘↩, ⇧↩, …).
    static func pressReturn() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        else { return }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
