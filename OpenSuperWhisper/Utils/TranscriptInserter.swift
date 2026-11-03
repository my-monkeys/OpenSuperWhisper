import AppKit
import CoreGraphics
import Foundation
import KeyboardShortcuts
import NaturalLanguage
import OpenSuperWhisperCore

/// The single place that decides *how* a finished transcription reaches the focused app:
/// clipboard stash, paste-vs-type, and the no-editable-target fallback.
///
/// Shared by the automatic insertion at the end of a dictation (`DictationPipeline`) and by any
/// explicit, user-triggered insertion, so the two can't drift apart.
enum TranscriptInserter {

    /// A transcription ready to go out, in the two forms it takes (#163).
    struct Prepared: Equatable {
        /// What goes in at the caret: fitted to the field when that is on and the field could
        /// be read, otherwise the same as `standalone`.
        let fitted: String
        /// The text as a sentence of its own, before any fitting. What the clipboard keeps and
        /// what a missed paste holds: the paste-last shortcut may take it to a sentence start,
        /// where a lowercase start and a dropped period would be wrong, and fits it again there.
        let standalone: String

        init(fitted: String, standalone: String) {
            self.fitted = fitted
            self.standalone = standalone
        }

        init(_ text: String) {
            self.init(fitted: text, standalone: text)
        }
    }

    /// Where an insertion left the text.
    enum Insertion: Equatable {
        /// In the field, or nowhere because auto-paste is off: nothing more to do.
        case done
        /// No field to put it in: it is on the clipboard, and the user is to be told ⌘V.
        case onClipboard
        /// A paste in pieces stopped part way (#165), or the keys typed into a remote session
        /// (#255), and Return must not follow: it would send half a prompt. What was left is held for the paste-last shortcut when a piece missed
        /// or another window came to the front, and dropped when a newer transcription took over
        /// or the dictation was thrown away.
        case cutShort
    }

    /// Inserts `text` into the focused app.
    ///
    /// - Parameters:
    ///   - text: Post-processed transcription, ready to insert; only its fitted form goes into
    ///     the field.
    ///   - honorAutoPastePreference: `true` for automatic insertion after a dictation, where the
    ///     "Auto-paste transcription" preference decides whether anything is inserted at all.
    ///     `false` when the user explicitly asked for this insertion — the request itself is the
    ///     intent, so a clipboard-only workflow still gets text where the cursor is.
    ///   - targetBundleID: the app being dictated into, for the per-app insertion rules. Passed by
    ///     the pipeline from the snapshot taken at record start rather than read here: transcription
    ///     runs in the background, so by the time this executes the frontmost app may be a different
    ///     one, and the rule has to be the one for the app the text is going to.
    ///   - submitting: Return is pressed once the text is in, which keeps a list paste plain
    ///     (#166, see `richText(for:into:submitting:)`).
    ///   - windowTitle: the title of the window it goes to, which tells Claude Code and Codex in a
    ///     terminal from a shell (#165). Taken when `targetBundleID` was, for the same reason.
    ///   - wanted: `false` once the dictation was thrown away, which stops a paste in pieces and
    ///     the keys typed into a remote session.
    /// - Returns: once the text is in, so Return can follow: for a paste in pieces, once the
    ///   last piece has been read.
    @MainActor
    @discardableResult
    static func insert(_ prepared: Prepared, honorAutoPastePreference: Bool,
                       targetBundleID: String? = nil, windowTitle: String? = nil,
                       submitting: Bool = false, wanted: () -> Bool = { true }) async -> Insertion {
        let text = prepared.fitted
        let prefs = AppPreferences.shared
        let rule = AppInsertionRule.rule(for: targetBundleID, in: prefs.appInsertionRules,
                                         disabled: prefs.perAppDisabledBundleIDs)
        noteNewerTranscription()
        // Whatever goes in now, a dictation, a paste-last or the pieces of a long prompt, is ours,
        // and a watch still reading the field would take it for the user's correction (#169).
        CorrectionWatch.endCurrent()

        let inserting = prefs.autoPasteTranscription || !honorAutoPastePreference
        // Above any rule: neither of the two modes a rule can pick gets through to the other
        // machine (#255).
        let remoteSession = RemoteSession.isRemoteSession(
            targetBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        // A rule for this app wins over the global switch, which is the whole point of having one.
        let pasting = inserting && !remoteSession
            && (rule.map { $0.mode == .paste } ?? prefs.pasteInsteadOfTyping)

        // Optional, independent clipboard stash. A paste leaves the text there itself once the
        // app has taken it; stashing first as well would hand clipboard histories a second copy.
        if prefs.autoCopyToClipboard && !pasting {
            ClipboardUtil.copyToClipboard(prepared.standalone)
        }

        guard inserting else { return .done }

        // Logged from here rather than from inside `TextInserter`, because this is where the
        // decision is made: which rule matched, which app it was resolved from, and which of the
        // two mechanisms ran. Logging it one layer down could only report the app in front right
        // now, which is not the one the rule came from once transcription has run in between.
        func log(mechanism: String, chunks: Int, pause: useconds_t,
                 pasteKeyCode: CGKeyCode? = nil) {
            TextInserter.logInsertion(payload: text, mechanism: mechanism,
                                      dictatedInto: targetBundleID, rule: rule,
                                      chunks: chunks, pause: pause, pasteKeyCode: pasteKeyCode)
        }

        if remoteSession {
            return await pressKeys(text, pace: rule?.typingPaceMilliseconds, wanted: wanted,
                                   log: { log(mechanism: "keystrokes", chunks: $0, pause: $1) })
        }

        if pasting {
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility check
            // can't read (Messages, Electron), and is a harmless no-op otherwise. So no editable-
            // target gate — it only ever produces false negatives (#paste-messages). A ⌘V that
            // nothing takes is caught afterwards instead, when nobody reads the text (#162).
            // One event, so there is nothing to pace and nothing to chunk, except for a long
            // prompt to Claude Code or Codex, which goes in a few pieces (#165). Logged all the
            // same: a report has to be able to say which mechanism ran, and a paste that logged
            // nothing looked exactly like an insertion that never happened.
            let pieces = agentPromptPieces(of: text, into: targetBundleID, windowTitle: windowTitle)
            log(mechanism: pieces.count > 1 ? "paste-pieces" : "paste", chunks: max(pieces.count, 1),
                pause: pieces.count > 1 ? useconds_t(AgentPromptPaste.pieceGap * 1_000_000) : 0,
                pasteKeyCode: KeyboardLayoutProvider.shared.pasteKeyCode())
            if pieces.count > 1 {
                return await pasteInPieces(pieces, standalone: prepared.standalone,
                                           keepOnClipboard: prefs.autoCopyToClipboard, wanted: wanted)
            }
            pasteThroughClipboard(prepared,
                                  rich: richText(for: prepared, into: targetBundleID, submitting: submitting),
                                  keepOnClipboard: prefs.autoCopyToClipboard)
            return .done
        }

        // Typing mode: synthetic keystrokes go wherever focus is, so only type when we're confident
        // there's an editable target; otherwise stash on the clipboard and notify ⌘V.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && Diag.measure("focusedElementIsEditable") { FocusUtils.focusedElementIsEditable() } == false
        if targetMissing {
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(prepared.standalone)
            }
            return .onClipboard
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
        return .done
    }

    /// Types into a remote session key by key (#255). No editable-field check: the field is on
    /// the other machine, and accessibility only ever sees the window that shows it.
    @MainActor
    private static func pressKeys(_ text: String, pace: Int?, wanted: () -> Bool,
                                  log: (_ strokes: Int, _ pause: useconds_t) -> Void) async -> Insertion {
        guard let map = KeystrokeMap.current() else {
            Diag.mark("remote session: keyboard layout unreadable, nothing typed")
            ClipboardUtil.copyToClipboard(text)
            return .onClipboard
        }
        let plan = map.plan(text)
        if !plan.skipped.isEmpty {
            Diag.mark("remote session: \(plan.skipped.count) characters no key of this layout types")
        }
        let pauseMilliseconds = pace ?? RemoteSession.defaultStrokePauseMilliseconds
        log(plan.strokes.count, TextInserter.microseconds(fromMilliseconds: pauseMilliseconds))
        let finished = await TextInserter.press(plan.strokes, pauseMilliseconds: pauseMilliseconds,
                                                wanted: wanted)
        return finished ? .done : .cutShort
    }

    /// The text exactly as it goes into the field: the post-processing every dictation gets,
    /// then, with "Match the text around the cursor" on, fitted to what the field holds (#163).
    ///
    /// Read here, after the focus is back in the field and right before the insertion, because
    /// the field is only worth reading once it is the one the text is going into. A field that
    /// cannot be read gets the text exactly as it would have without the setting.
    ///
    /// - Parameters:
    ///   - fitToField: the setting is on and the text is going to be inserted. Text that only
    ///     goes to the clipboard has no caret to fit, and the field is then not read at all.
    ///   - language: the language the text was dictated in, nil or "auto" when unknown.
    ///   - readField: the focused field, passed in so tests never read a real one.
    @MainActor
    static func prepared(_ text: String, fitToField: Bool, language: String?,
                         readField: () -> TextAroundCaret? = TextAroundCaret.focused) -> Prepared {
        let processed = IndicatorViewModel.applyPostProcessing(text)
        guard fitToField else { return Prepared(processed) }
        guard let field = Diag.measure("TextAroundCaret.focused", readField) else {
            Diag.mark("caret match: field unreadable, text left as is")
            return Prepared(processed)
        }
        let prefs = AppPreferences.shared
        let terms = prefs.customDictionaryEnabled
            ? CustomDictionary.spellings(entries: prefs.customDictionaryEntries) : []
        // A snippet's text is written the way the user typed it: "Max Costa" at the start of a
        // signature keeps its capital even when the caret is mid-sentence, and "See you soon!"
        // its exclamation mark before the next word (#167).
        let snippetTexts = prefs.snippetsEnabled
            ? prefs.snippets.filter(\.isComplete).map(\.trimmedExpansion) : []
        let core = processed.trimmingCharacters(in: .whitespaces)
        let endsWithSnippet = snippetTexts.contains { core.hasSuffix($0) }
        let known = language == "auto" ? nil : language
        let adjustCase = CaretTextMatcher.adjustsCase(
            language: known ?? guessedLanguage(of: processed, after: field.before))
        let fitted = CaretTextMatcher.fit(processed, into: field, properNouns: Set(terms + snippetTexts),
                                          adjustCase: adjustCase, keepsFinalMark: endsWithSnippet)
        Diag.mark("caret match: \(fitted == processed ? "nothing to change" : "fitted to the field")")
        return Prepared(fitted: fitted, standalone: processed)
    }

    /// With auto-detect the engine does not say which language it heard, so it is read from the
    /// dictation and the sentence before the caret together: a few words alone are too short to
    /// tell German from English reliably.
    static func guessedLanguage(of dictation: String, after before: String) -> String? {
        let sample = String(before.suffix(guessSampleLength)) + " " + dictation
        return NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
    }

    static let guessSampleLength = 300

    // MARK: - Paste that didn't land (#162)

    /// The last transcription whose paste nobody took, held in memory so the paste-last shortcut
    /// reaches it even with history off. Cleared by the next transcription to go anywhere, which
    /// is newer.
    @MainActor private(set) static var unlandedPaste: String?
    @MainActor private(set) static var insertionCount = 0

    /// A newer transcription has gone somewhere: into the focused app, or back to an agent that
    /// asked for it. From now on that one is "the last dictation", not an older missed paste.
    @MainActor
    static func noteNewerTranscription() {
        insertionCount += 1
        unlandedPaste = nil
    }

    /// Keeps a dictation that has nowhere to go: the app it was dictated into quit, or would not
    /// come back to the front, before the text was ready (#164). It is never inserted into
    /// whatever is in front instead, which is the wrong field by definition. The paste-last
    /// shortcut reaches it either way; the clipboard gets it only when the user is told, or keeps
    /// dictations there anyway, so a silent fallback never replaces what they had copied (#44).
    @MainActor
    static func holdUndelivered(_ text: String, onClipboard: Bool,
                                pasteboard: NSPasteboard = .general) {
        noteNewerTranscription()
        unlandedPaste = text
        if onClipboard {
            ClipboardUtil.copyToClipboard(text, to: pasteboard)
        }
    }

    /// The list in the text going into the field as rich text for the app it is pasted into,
    /// with "Lists as bullets" on (#166). Only the paste carries it: the clipboard keeps the plain
    /// lines afterwards, which read the same in any app the user takes them to.
    ///
    /// Not when Return follows the paste: the caret is then in the last item of a real list, and
    /// a rich editor (Slack, a chat composer in a browser) takes Return there as a new bullet
    /// rather than a send. The plain lines send the way they always did.
    @MainActor
    static func richText(for prepared: Prepared, into bundleID: String?,
                         submitting: Bool) -> RichPasteText? {
        guard !submitting, AppPreferences.shared.pasteListsAsRichText,
              let rich = RichListPaste.richText(for: prepared.fitted, into: bundleID) else { return nil }
        Diag.mark("rich paste: list offered as RTF and HTML")
        return rich
    }

    /// Pastes through the clipboard and watches whether the app in front took the text.
    @MainActor
    private static func pasteThroughClipboard(_ prepared: Prepared, rich: RichPasteText?,
                                              keepOnClipboard: Bool) {
        pasteThroughClipboard(prepared.fitted, rich: rich, standalone: prepared.standalone,
                              keepOnClipboard: keepOnClipboard,
                              retryShortcut: KeyboardShortcuts.getShortcut(for: .pasteLastTranscription)?.description,
                              warnWhenMissed: AppPreferences.shared.notifyWhenNoPasteTarget,
                              paste: { Diag.measure("TextInserter.paste") { TextInserter.paste() } })
    }

    /// The paste itself, with everything it reads from the system passed in so tests can run it
    /// on a private pasteboard without posting a keystroke.
    ///
    /// - Parameters:
    ///   - rich: `text` as RTF and HTML, offered beside it on the same item (#166).
    ///   - standalone: what the clipboard keeps and a missed paste holds once the paste is over,
    ///     the text before it was fitted to the field. Only the paste itself carries `text`.
    ///   - retryShortcut: the paste-last shortcut, `nil` when none is bound.
    ///   - warnWhenMissed: "Warn when no field is focused". Read once, here, so the clipboard
    ///     decision and the notice can't disagree if the setting changes during the paste.
    @MainActor
    static func pasteThroughClipboard(_ text: String, rich: RichPasteText? = nil,
                                      standalone: String? = nil,
                                      keepOnClipboard: Bool,
                                      retryShortcut: String?, warnWhenMissed: Bool,
                                      on pasteboard: NSPasteboard = .general,
                                      timing: ClipboardUtil.PasteTiming = .current,
                                      paste: () -> Void) {
        let afterMissing = afterMissedPaste(keepOnClipboard: keepOnClipboard,
                                            pasteLastBound: retryShortcut != nil,
                                            warnWhenMissed: warnWhenMissed)
        let insertion = insertionCount
        let retryKeys = afterMissing == .previousContents ? retryShortcut ?? "⌘V" : "⌘V"
        // With "Copy to clipboard" off the clipboard is only the paste vehicle (#44): the
        // previous contents come back once the paste is done.
        let kept = standalone ?? text
        ClipboardUtil.borrowForPaste(text, rich: rich, keeping: kept, on: pasteboard,
                                     afterLanding: keepOnClipboard ? .transcription : .previousContents,
                                     afterMissing: afterMissing,
                                     timing: timing,
                                     paste: paste,
                                     outcome: { outcome in
            guard outcome == .missed else { return }
            MainActor.assumeIsolated {
                reportMissedPaste(kept, insertion: insertion, retryKeys: retryKeys,
                                  warn: warnWhenMissed)
            }
        })
    }

    /// Where the clipboard is left when a paste missed. The text must stay reachable: through
    /// the paste-last shortcut when one is set (and then the user's clipboard still comes back),
    /// and otherwise on the clipboard for a manual ⌘V, which costs the previous contents but not
    /// the words. That trade is only made when the notice says so: unannounced, the user would
    /// find their clipboard replaced without knowing why — the #44 regression, now triggered by
    /// any slow app that reads after the deadline. History and the shortcut still keep the words.
    static func afterMissedPaste(keepOnClipboard: Bool, pasteLastBound: Bool,
                                 warnWhenMissed: Bool) -> ClipboardUtil.Afterwards {
        if keepOnClipboard { return .transcription }
        return pasteLastBound || !warnWhenMissed ? .previousContents : .transientTranscription
    }

    @MainActor
    static func reportMissedPaste(_ text: String, insertion: Int, retryKeys: String,
                                          warn: Bool) {
        print("Paste was not taken by the frontmost app within the deadline")
        // A newer insertion has started since: the text the shortcut should reach is that one.
        guard insertion == insertionCount else { return }
        unlandedPaste = text
        guard warn else { return }
        IndicatorWindowManager.shared.flash(.info(missedPasteNotice(retryKeys: retryKeys)))
    }

    static func missedPasteNotice(retryKeys: String) -> String {
        String(localized: "Not pasted — press \(retryKeys) to paste it")
    }
}
