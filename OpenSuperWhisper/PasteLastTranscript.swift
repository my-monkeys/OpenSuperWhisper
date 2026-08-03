import AppKit
import Foundation
import WhisperCore

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
    /// Skips clips that failed (their `transcription` holds the retry placeholder), clips still
    /// being transcribed (partial or empty text), and ones that produced nothing. Ordering is
    /// computed here rather than trusted from the caller, so a change in how the store sorts
    /// can't silently start pasting an old transcription.
    static func pick(from recordings: [Recording]) -> String? {
        recordings
            .filter { $0.status == .completed && !$0.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max { $0.timestamp < $1.timestamp }?
            .transcription
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

        await waitForModifiersToClear()

        // `honorAutoPastePreference: false` — pressing the shortcut *is* the request to insert, so
        // a user who dictates to the clipboard only still gets text where the cursor is.
        let targetMissing = TranscriptInserter.insert(IndicatorViewModel.applyPostProcessing(text),
                                                      honorAutoPastePreference: false)
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
