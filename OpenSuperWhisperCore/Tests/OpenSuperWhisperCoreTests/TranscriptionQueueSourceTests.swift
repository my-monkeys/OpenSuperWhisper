import XCTest

@testable import OpenSuperWhisperCore

/// Which audio a rerun reads. A dictation has no source file and is read from its own
/// recording; saving that path as `sourceFileURL` made Home show it as an imported file (#274),
/// so the queue resolves it without ever writing it back.
@MainActor
final class TranscriptionQueueSourceTests: CoreTestCase {

    private var created: [URL] = []

    override func tearDownWithError() throws {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
        created.append(url)
    }

    private func recording(source: String?) -> Recording {
        Recording(id: UUID(), timestamp: Date(), fileName: "\(UUID().uuidString).wav", transcription: "text",
                  duration: 1, status: .completed, progress: 1, sourceFileURL: source)
    }

    func testDictationIsReadFromItsOwnRecording() throws {
        let dictation = recording(source: nil)
        try touch(dictation.url)

        XCTAssertEqual(TranscriptionQueue.existingAudioSource(of: dictation), dictation.url)
        XCTAssertNil(dictation.sourceFileURL)
    }

    func testImportIsReadFromItsOriginalFile() throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try touch(original)
        let imported = recording(source: original.path)
        try touch(imported.url)

        XCTAssertEqual(TranscriptionQueue.existingAudioSource(of: imported), original)
    }

    func testImportWhoseOriginalIsGoneFallsBackToItsRecording() throws {
        let imported = recording(source: "/nonexistent/original.m4a")
        try touch(imported.url)

        XCTAssertEqual(TranscriptionQueue.existingAudioSource(of: imported), imported.url)
    }

    func testNothingToReadWhenBothFilesAreGone() {
        XCTAssertNil(TranscriptionQueue.existingAudioSource(of: recording(source: nil)))
        XCTAssertNil(TranscriptionQueue.existingAudioSource(of: recording(source: "/nonexistent/original.m4a")))
    }
}
