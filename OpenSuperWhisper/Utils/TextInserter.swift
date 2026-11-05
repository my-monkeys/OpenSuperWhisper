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

    /// Default pause between chunks, so the receiving app gets a chance to process each one.
    ///
    /// Unpaced, a 400-character dictation is ~40 key events posted inside a millisecond. An app
    /// that re-renders its whole input area per keystroke falls behind, and its buffer and caret
    /// drift apart: reported as existing text duplicated two or three times with the new speech
    /// wedged inside, in a terminal TUI, and it got likelier the fuller the input box already was
    /// (#85). Paste mode was unaffected, which is one event instead of forty.
    ///
    /// Two milliseconds is not enough for the app that produced the report, and the reason is that
    /// the cost this has to cover is the target's redraw, which scales with what the box already
    /// holds rather than with what we are sending. A short dictation into a long message therefore
    /// gets the least pacing exactly where it needs the most, and no single constant fixes that.
    /// Measured there at 10ms of total pacing into a 400-character box, still corrupt. So this is
    /// a default that can be raised, globally and per app, rather than the answer.
    static let defaultChunkPauseMilliseconds = 2

    /// Anything above this is almost certainly a mistake rather than a preference: at 50ms a
    /// 400-character dictation would take two seconds of blocked main thread.
    static let maxChunkPauseMilliseconds = 50

    static var chunkPauseMicroseconds: useconds_t {
        microseconds(fromMilliseconds: AppPreferences.shared.typingPaceMilliseconds)
    }

    static func microseconds(fromMilliseconds milliseconds: Int) -> useconds_t {
        useconds_t(min(max(milliseconds, 0), maxChunkPauseMilliseconds)) * 1_000
    }

    /// Ceiling on the delay this adds in total. Typing runs on the main thread, and it has to:
    /// the caller presses Return after it returns, so going async would race the submit key
    /// against the text. A very long dictation therefore trades pacing for responsiveness rather
    /// than freezing the app.
    static let maxTotalPauseMicroseconds: useconds_t = 500_000

    /// How long to wait between chunks for a text of `chunkCount` chunks, given a requested pace.
    static func chunkPause(forChunkCount chunkCount: Int,
                           requested: useconds_t = TextInserter.chunkPauseMicroseconds) -> useconds_t {
        guard chunkCount > 1, requested > 0 else { return 0 }
        let gaps = useconds_t(chunkCount - 1)
        return min(requested, maxTotalPauseMicroseconds / gaps)
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
    /// - Parameters:
    ///   - app: the app actually receiving the events, read now.
    ///   - dictatedInto: the app the clip was recorded in, which is what the per-app rule was
    ///     resolved from. The two differ whenever the user switches apps while transcription
    ///     runs, and their disagreement is itself worth seeing: the pace on this line came from
    ///     the second, so a line that named only the first would attribute one app's rule to
    ///     another and send triage into the settings code.
    ///   - rule: what the rule lookup decided, so a rule that matched can be told apart from one
    ///     that silently did not. A typo in a bundle identifier and no rule at all otherwise
    ///     produce the same line, and that is the first question anyone reading #85 now asks.
    ///   - pasteKeyCode: the key posted with ⌘ when pasting, which depends on the keyboard layout
    ///     (#161). A paste that lands as some other shortcut is answered by this number alone.
    static func insertionLogLine(app: String, dictatedInto: String?, rule: String,
                                 mechanism: String, targetLength: Int?, caret: Int?,
                                 payload: Int, chunks: Int, pause: useconds_t,
                                 pasteKeyCode: CGKeyCode? = nil) -> String {
        let gaps = max(chunks - 1, 0)
        let target = targetLength.map(String.init) ?? "unavailable"
        let caretText = caret.map(String.init) ?? "unavailable"
        let key = pasteKeyCode.map { String(format: " key=0x%02X", $0) } ?? ""
        return "insert via=\(mechanism) app=\(app) dictated-into=\(dictatedInto ?? "unknown") "
            + "rule=\(rule) target=\(target) caret=\(caretText) payload=\(payload) "
            + "chunks=\(chunks) pause=\(pause)us/gap total=\(UInt(pause) * UInt(gaps))us\(key)"
    }

    /// How a rule reads on the diagnostic line.
    static func ruleDescription(_ rule: AppInsertionRule?) -> String {
        guard let rule else { return "none" }
        guard rule.mode == .type, let pace = rule.typingPaceMilliseconds else {
            return rule.mode.rawValue
        }
        return "\(rule.mode.rawValue)@\(pace)ms"
    }

    /// Reads the target's state and logs the line. Skipped entirely when diagnostics are off: the
    /// accessibility read costs up to 32ms, and the insertion path should not pay that to log
    /// nothing.
    /// Called by `TranscriptInserter`, which is where the rule and the recorded app are known.
    /// Logging from inside `type()` could only see the app in front right now, which is not the
    /// one the decision was made for.
    static func logInsertion(payload: String, mechanism: String, dictatedInto: String?,
                             rule: AppInsertionRule?, chunks: Int, pause: useconds_t,
                             pasteKeyCode: CGKeyCode? = nil) {
        guard Diag.isEnabled else { return }
        let metrics = FocusUtils.focusedTextMetrics()
        Diag.mark(insertionLogLine(
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            dictatedInto: dictatedInto,
            rule: ruleDescription(rule),
            mechanism: mechanism,
            targetLength: metrics?.length,
            caret: metrics?.caret,
            payload: payload.count,
            chunks: chunks,
            pause: pause,
            pasteKeyCode: pasteKeyCode))
    }

    /// - Parameter paceMilliseconds: gap between chunks. Defaults to the global setting; a
    ///   per-app rule passes its own, because the app being dictated into is what decides how
    ///   much pacing is needed.
    static func type(_ text: String, paceMilliseconds: Int? = nil) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let allChunks = chunks(of: text)
        let requested = paceMilliseconds.map(microseconds(fromMilliseconds:)) ?? chunkPauseMicroseconds
        let pause = chunkPause(forChunkCount: allChunks.count, requested: requested)

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
    /// V is whichever key types "v" with ⌘ held in the current layout, not the US position (#161).
    static func paste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cmdKey: CGKeyCode = 0x37 // kVK_Command
        let vKey = KeyboardLayoutProvider.shared.pasteKeyCode()
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

    /// Presses `strokes` one at a time, Shift and Option as real keys around the ones that need
    /// them, for an app that forwards key codes rather than text (#255).
    ///
    /// Async, unlike `type`: every key of a remote session is paced, which for a long dictation
    /// adds up to seconds the main thread must not be held for. Stops as soon as `wanted` turns
    /// false, and returns whether every key went out.
    @MainActor
    static func press(_ strokes: [KeyStroke], pauseMilliseconds: Int,
                      wanted: () -> Bool = { true }) async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let pause = min(max(pauseMilliseconds, 0), maxChunkPauseMilliseconds)
        for stroke in strokes {
            guard wanted() else { return false }
            post(stroke, source: source)
            if pause > 0 {
                try? await Task.sleep(for: .milliseconds(pause))
            }
        }
        return true
    }

    /// The flags are set on every event, the modifier keys' own included, so a dictation hotkey
    /// still held down cannot turn a letter into a shortcut.
    private static func post(_ stroke: KeyStroke, source: CGEventSource) {
        let shiftKey: CGKeyCode = 0x38  // kVK_Shift
        let optionKey: CGKeyCode = 0x3A // kVK_Option
        var flags: CGEventFlags = []
        func send(_ keyCode: CGKeyCode, down: Bool) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        if stroke.shift {
            flags.insert(.maskShift)
            send(shiftKey, down: true)
        }
        if stroke.option {
            flags.insert(.maskAlternate)
            send(optionKey, down: true)
        }
        send(stroke.keyCode, down: true)
        send(stroke.keyCode, down: false)
        if stroke.option {
            flags.remove(.maskAlternate)
            send(optionKey, down: false)
        }
        if stroke.shift {
            flags.remove(.maskShift)
            send(shiftKey, down: false)
        }
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
