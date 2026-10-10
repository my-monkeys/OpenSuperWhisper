import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Dropping a file while transcription history is off asks before saving it. The question is a
/// closure the queue is given, the app's NSAlert in the shipped build, so these answer it
/// without a window.
@MainActor
final class HistoryConsentTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private var root: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        scratch = ScratchPreferences()
        // On by default, so a fresh store would never ask.
        AppPreferences.shared.saveTranscriptionHistory = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryConsentTests-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(storageRoot: root)
    }

    override func tearDown() async throws {
        scratch.restore()
        try? FileManager.default.removeItem(at: root)
    }

    func testDecliningLeavesHistoryOffAndQueuesNothing() async throws {
        let answers = Answers(reply: false)
        let queue = makeQueue(answers)

        await queue.addFileToQueue(url: Fixtures.jfkWav)

        XCTAssertEqual(answers.asked, 1)
        XCTAssertFalse(AppPreferences.shared.saveTranscriptionHistory)
        XCTAssertTrue(store.getPendingRecordings().isEmpty)
        let all = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(queue.isProcessing)
    }

    /// The file does not exist, so nothing is transcribed: the queue's first pass drops a
    /// recording whose source is gone before it reaches an engine.
    func testAcceptingTurnsHistoryOnAndQueuesTheFile() async throws {
        let answers = Answers(reply: true)
        let queue = makeQueue(answers)
        let missing = root.appendingPathComponent("missing.wav")

        await queue.addFileToQueue(url: missing)

        XCTAssertEqual(answers.asked, 1)
        XCTAssertTrue(AppPreferences.shared.saveTranscriptionHistory)
        let queued = store.getPendingRecordings()
        XCTAssertEqual(queued.map(\.sourceFileURL), [missing.path])

        try await waitUntil { !queue.isProcessing }
        try await waitUntil { self.store.getPendingRecordings().isEmpty }
    }

    private func makeQueue(_ answers: Answers) -> TranscriptionQueue {
        TranscriptionQueue(transcriptionService: .shared, recordingStore: store,
                           makeSettings: { Settings() },
                           confirmEnableHistory: { answers.answer() })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class Answers {
    private let reply: Bool
    private(set) var asked = 0

    init(reply: Bool) { self.reply = reply }

    func answer() -> Bool {
        asked += 1
        return reply
    }
}
