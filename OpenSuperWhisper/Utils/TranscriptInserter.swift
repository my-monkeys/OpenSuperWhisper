import Foundation

/// The single place that decides *how* a finished transcription reaches the focused app:
/// clipboard stash, paste-vs-type, and the no-editable-target fallback.
///
/// Shared by the automatic insertion at the end of a dictation (`DictationPipeline`) and by any
/// explicit, user-triggered insertion, so the two can't drift apart.
enum TranscriptInserter {

    /// Inserts `text` into the focused app.
    ///
    /// - Parameters:
    ///   - text: Post-processed transcription, ready to insert.
    ///   - honorAutoPastePreference: `true` for automatic insertion after a dictation, where the
    ///     "Auto-paste transcription" preference decides whether anything is inserted at all.
    ///     `false` when the user explicitly asked for this insertion — the request itself is the
    ///     intent, so a clipboard-only workflow still gets text where the cursor is.
    ///   - targetBundleID: the app being dictated into, for the per-app insertion rules. Passed by
    ///     the pipeline from the snapshot taken at record start rather than read here: transcription
    ///     runs in the background, so by the time this executes the frontmost app may be a different
    ///     one, and the rule has to be the one for the app the text is going to.
    /// - Returns: `true` when insertion was skipped because no editable field was focused, so the
    ///   caller can leave the text on the clipboard and notify ⌘V.
    @MainActor
    @discardableResult
    static func insert(_ text: String, honorAutoPastePreference: Bool,
                       targetBundleID: String? = nil) -> Bool {
        let prefs = AppPreferences.shared
        let rule = AppInsertionRule.rule(for: targetBundleID, in: prefs.appInsertionRules)

        // Optional, independent clipboard stash (never the insertion mechanism).
        if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(text)
        }

        guard prefs.autoPasteTranscription || !honorAutoPastePreference else { return false }

        // A rule for this app wins over the global switch, which is the whole point of having one.
        let pasting = rule.map { $0.mode == .paste } ?? prefs.pasteInsteadOfTyping

        // Logged from here rather than from inside `TextInserter`, because this is where the
        // decision is made: which rule matched, which app it was resolved from, and which of the
        // two mechanisms ran. Logging it one layer down could only report the app in front right
        // now, which is not the one the rule came from once transcription has run in between.
        func log(mechanism: String, chunks: Int, pause: useconds_t) {
            TextInserter.logInsertion(payload: text, mechanism: mechanism,
                                      dictatedInto: targetBundleID, rule: rule,
                                      chunks: chunks, pause: pause)
        }

        if pasting {
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility check
            // can't read (Messages, Electron), and is a harmless no-op otherwise. So no editable-
            // target gate — it only ever produces false negatives (#paste-messages).
            // One event, so there is nothing to pace and nothing to chunk. Logged all the same:
            // a report has to be able to say which mechanism ran, and a paste that logged
            // nothing looked exactly like an insertion that never happened.
            log(mechanism: "paste", chunks: 1, pause: 0)
            if prefs.autoCopyToClipboard {
                Diag.measure("TextInserter.paste") { TextInserter.paste() }
            } else {
                // The clipboard is only the paste vehicle here — the user opted out of keeping the
                // text on it (#44) — so put the previous contents back after the ⌘V lands.
                ClipboardUtil.borrowForPaste(text) {
                    Diag.measure("TextInserter.paste") { TextInserter.paste() }
                }
            }
            return false
        }

        // Typing mode: synthetic keystrokes go wherever focus is, so only type when we're confident
        // there's an editable target; otherwise stash on the clipboard and notify ⌘V.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && Diag.measure("focusedElementIsEditable") { FocusUtils.focusedElementIsEditable() } == false
        if targetMissing {
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(text)
            }
            return true
        }
        let pace = rule?.typingPaceMilliseconds
        let chunkCount = TextInserter.chunks(of: text).count
        let requested = pace.map(TextInserter.microseconds(fromMilliseconds:))
            ?? TextInserter.chunkPauseMicroseconds
        log(mechanism: "type", chunks: chunkCount,
            pause: TextInserter.chunkPause(forChunkCount: chunkCount, requested: requested))

        Diag.measure("TextInserter.type") {
            TextInserter.type(text, paceMilliseconds: pace)
        }
        return false
    }
}
