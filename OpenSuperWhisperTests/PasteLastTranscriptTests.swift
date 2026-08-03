import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper
@testable import WhisperCore

/// Covers which stored recording the "paste last transcription" shortcut re-pastes: the newest
/// one that actually produced text. Failed clips (whose `transcription` holds the retry
/// placeholder), clips still being transcribed, and empty results must all be skipped, or the
/// shortcut pastes a placeholder — or nothing — instead of the user's last dictation.
///
/// The insertion itself isn't covered here: it synthesizes real keystrokes into whatever app has
/// focus, which a unit test has no business doing. It goes through `TranscriptInserter`, the same
/// path the end-of-dictation insertion uses.
final class PasteLastTranscriptTests: XCTestCase {

    private func makeRecording(_ transcription: String,
                               status: RecordingStatus = .completed,
                               secondsAgo: TimeInterval) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            fileName: "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 1,
            status: status,
            progress: 1,
            sourceFileURL: nil
        )
    }

    func testPicksTheNewestCompletedTranscription() {
        let text = PasteLastTranscript.pick(from: [
            makeRecording("newest", secondsAgo: 0),
            makeRecording("older", secondsAgo: 60),
        ])

        XCTAssertEqual(text, "newest")
    }

    func testOrdersByTimestampNotArrayPosition() {
        // The store hands them over newest-first, but nothing in the type enforces that.
        let text = PasteLastTranscript.pick(from: [
            makeRecording("older", secondsAgo: 60),
            makeRecording("newest", secondsAgo: 0),
        ])

        XCTAssertEqual(text, "newest")
    }

    func testSkipsFailedRecordings() {
        // A failed clip stores the retry placeholder as its transcription — pasting that would
        // drop "Transcription failed — click ↻ to try again." into the user's document.
        let text = PasteLastTranscript.pick(from: [
            makeRecording("Transcription failed — click ↻ to try again.", status: .failed, secondsAgo: 0),
            makeRecording("real transcription", secondsAgo: 60),
        ])

        XCTAssertEqual(text, "real transcription")
    }

    func testSkipsRecordingsStillInFlight() {
        for status in [RecordingStatus.pending, .converting, .transcribing] {
            let text = PasteLastTranscript.pick(from: [
                makeRecording("partial…", status: status, secondsAgo: 0),
                makeRecording("finished", secondsAgo: 60),
            ])

            XCTAssertEqual(text, "finished", "status \(status.rawValue) should be skipped")
        }
    }

    func testSkipsBlankTranscriptions() {
        let text = PasteLastTranscript.pick(from: [
            makeRecording("   \n ", secondsAgo: 0),
            makeRecording("", secondsAgo: 30),
            makeRecording("finished", secondsAgo: 60),
        ])

        XCTAssertEqual(text, "finished")
    }

    func testReturnsNilWhenNothingIsPastable() {
        XCTAssertNil(PasteLastTranscript.pick(from: []))
        XCTAssertNil(PasteLastTranscript.pick(from: [
            makeRecording("nope", status: .failed, secondsAgo: 0),
            makeRecording("  ", secondsAgo: 60),
        ]))
    }

    func testKeepsTheStoredTextVerbatim() {
        // Leading/trailing whitespace only decides whether a clip counts as blank; the text that
        // gets pasted is whatever was stored, so post-processing sees exactly what it saw the
        // first time round.
        let text = PasteLastTranscript.pick(from: [makeRecording(" hello there ", secondsAgo: 0)])

        XCTAssertEqual(text, " hello there ")
    }

    func testShortcutIsUnboundByDefault() {
        // Opt-in: the feature must not claim a global combination on upgrade. Users assign one in
        // Settings > Shortcuts.
        XCTAssertNil(KeyboardShortcuts.Name.pasteLastTranscription.defaultShortcut)
    }
}
