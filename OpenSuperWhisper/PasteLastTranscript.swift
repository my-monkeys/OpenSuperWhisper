import AppKit
import Foundation

/// Re-inserts the most recent transcription into the focused app on demand.
///
/// Dictation inserts once, wherever the caret happened to be. This puts the same text somewhere
/// else — a second field, a chat window, a commit message — without re-recording it, and without
/// requiring the transcription to still be on the clipboard. That matters for anyone who leaves
/// "Copy to clipboard" off precisely so dictation stops trampling what they had copied: they lose
/// the text the moment it is inserted, and re-dictating is the only way to get it back.
///
/// Unbound by default; a shortcut is assigned in Settings > Shortcuts.
enum PasteLastTranscript {

    /// How many recent recordings are scanned for a re-pastable transcription. Only failed,
    /// in-flight and empty clips are skipped, so the newest usable one is nearly always within
    /// the first few rows.
    static let scanDepth = 20

    /// The newest transcription worth pasting, or `nil` when there isn't one yet.
    ///
    /// What counts as worth pasting lives in [RecentTranscripts], so this and the status bar's
    /// "Recent" submenu can't drift into disagreeing about which clips are usable.
    static func pick(from recordings: [Recording]) -> String? {
        RecentTranscripts.pick(from: recordings, limit: 1).first?.transcription
    }

    /// Handles one press of the shortcut: find the last transcription and insert it.
    @MainActor
    static func run() async {
        let recordings: [Recording]
        do {
            recordings = try await RecordingStore.shared.fetchRecordings(limit: scanDepth, offset: 0)
        } catch {
            print("Paste last transcription: failed to read recordings: \(error)")
            IndicatorWindowManager.shared.flash(.error("Couldn't read transcriptions"))
            return
        }

        guard let text = pick(from: recordings) else {
            IndicatorWindowManager.shared.flash(.info("No transcription to paste yet"))
            return
        }

        await insert(text)
    }

    /// Puts a chosen transcription where the caret is. Shared with the status bar's "Recent"
    /// submenu, which reaches the same text by a different route.
    @MainActor
    static func insert(_ text: String) async {
        await waitForModifiersToClear()

        // `honorAutoPastePreference: false` — asking for this insertion *is* the request, so a
        // user who dictates to the clipboard only still gets text where the cursor is.
        //
        // The target here is whatever is frontmost right now, unlike the pipeline, which uses the
        // app that was frontmost when the clip was recorded. This insertion has no earlier moment
        // to refer back to: the request is being made now, at this window.
        let targetMissing = TranscriptInserter.insert(
            IndicatorViewModel.applyPostProcessing(text),
            honorAutoPastePreference: false,
            targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        if targetMissing {
            IndicatorWindowManager.shared.flash(.info("Copied — press ⌘V"))
        }
    }

    /// Waits (briefly) for the shortcut's own modifiers to come back up.
    ///
    /// The insertion is a synthetic ⌘V, and macOS merges the physically-held modifiers into it.
    /// Fire while ⌃⌘ is still down and the frontmost app sees ⌃⌘V — not a paste — so the text
    /// silently fails to appear. Typing mode is just as exposed: held modifiers turn the
    /// keystrokes into shortcuts.
    @MainActor
    static func waitForModifiersToClear(timeout: TimeInterval = 1.0,
                                        pollInterval: TimeInterval = 0.02) async {
        let deadline = Date().addingTimeInterval(timeout)
        while modifiersAreHeld(), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    @MainActor
    private static func modifiersAreHeld() -> Bool {
        !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
