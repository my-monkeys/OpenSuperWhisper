import XCTest

@testable import OpenSuperWhisper

/// A dictation's audio survives a crash, a quit and a failed transcription, and is offered back
/// until it is transcribed, discarded or a week old (#253).
@MainActor
final class UnfinishedDictationsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfinished-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) -> URL {
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    private func takeName(secondsAgo: Int, id: String = "ab12cd34") -> String {
        "rec-\(Int(Date().timeIntervalSince1970) - secondsAgo)-\(id).wav"
    }

    private func waitForDrain(_ pipeline: DictationPipeline) async {
        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }

    // MARK: Header repair

    func testRepairRestoresTheSizesOfACutWAV() {
        let cut = WAVHeaderRepair.syntheticWAV(seconds: 3, staleSizes: true)
        let repaired = WAVHeaderRepair.repair(header: cut.prefix(WAVHeaderRepair.headerWindow),
                                              fileLength: UInt64(cut.count))
        XCTAssertEqual(repaired?.audioBytes, 192_000)
        XCTAssertEqual(repaired?.duration ?? 0, 3, accuracy: 0.001)
        let clean = WAVHeaderRepair.syntheticWAV(seconds: 3, staleSizes: false)
        XCTAssertEqual(repaired?.header, Data(clean.prefix(WAVHeaderRepair.headerWindow)), "the repaired header is the one a clean close writes")
    }

    func testRepairDropsATrailingPartialFrame() {
        let cut = WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: true) + Data([1, 2, 3])
        let repaired = WAVHeaderRepair.repair(header: cut.prefix(WAVHeaderRepair.headerWindow),
                                              fileLength: UInt64(cut.count))
        XCTAssertEqual(repaired?.audioBytes, 64_000)
    }

    func testRepairLeavesACleanFileAlone() {
        let clean = WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: false)
        let head = clean.prefix(WAVHeaderRepair.headerWindow)
        XCTAssertEqual(WAVHeaderRepair.repair(header: head, fileLength: UInt64(clean.count))?.header, Data(head))
    }

    func testRepairFindsNoAudioInAHeaderOnlyFileOrNonWAV() {
        let empty = WAVHeaderRepair.syntheticWAV(seconds: 0, staleSizes: true)
        XCTAssertNil(WAVHeaderRepair.repair(header: empty, fileLength: UInt64(empty.count)))
        XCTAssertNil(WAVHeaderRepair.repair(header: Data("not a wav file at all".utf8), fileLength: 21))
    }

    func testRepairFileFixesTheFileOnDisk() throws {
        let url = write("cut.wav", WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: true))
        XCTAssertEqual(WAVHeaderRepair.repairFile(at: url) ?? 0, 2, accuracy: 0.001)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: false))
    }

    // MARK: Startup scan

    func testScanOffersCutTakesOldestFirstAndSkipsOwnedOnes() {
        write(takeName(secondsAgo: 60, id: "aaaaaaaa"), WAVHeaderRepair.syntheticWAV(seconds: 4, staleSizes: true))
        write(takeName(secondsAgo: 600, id: "bbbbbbbb"), WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: true))
        let owned = takeName(secondsAgo: 5, id: "cccccccc")
        let ownedURL = write(owned, WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: true))

        let clips = UnfinishedDictations.scan(in: directory, owned: [owned], now: Date())

        XCTAssertEqual(clips.map(\.url.lastPathComponent).map { String($0.suffix(12)) },
                       ["bbbbbbbb.wav", "aaaaaaaa.wav"])
        XCTAssertEqual(clips.map(\.duration).first ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(try? Data(contentsOf: ownedURL), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: true),
                       "a clip the pipeline owns is neither listed nor touched")
    }

    func testScanDeletesEmptyAndExpiredTakes() {
        let empty = write(takeName(secondsAgo: 60, id: "eeeeeeee"), WAVHeaderRepair.syntheticWAV(seconds: 0, staleSizes: true))
        let weekOld = UnfinishedDictations.retentionDays * 86_400
        let expired = write(takeName(secondsAgo: weekOld + 60, id: "dddddddd"), WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: true))
        let fresh = write(takeName(secondsAgo: weekOld - 3_600, id: "ffffffff"), WAVHeaderRepair.syntheticWAV(seconds: 2, staleSizes: true))

        let clips = UnfinishedDictations.scan(in: directory, owned: [], now: Date())

        XCTAssertEqual(clips.map(\.url.lastPathComponent), [fresh.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    }

    func testMigrationMovesOldTakesAndLeavesThePrimingFile() throws {
        let legacy = directory.appendingPathComponent("temp_recordings", isDirectory: true)
        let target = directory.appendingPathComponent("unfinished", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let take = legacy.appendingPathComponent(takeName(secondsAgo: 60))
        let primed = legacy.appendingPathComponent("primed.wav")
        let stale = legacy.appendingPathComponent(takeName(secondsAgo: 60, id: "99999999"))
        for url in [take, primed, stale] {
            try WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: true).write(to: url)
        }
        let weekAgo = Date().addingTimeInterval(-Double(UnfinishedDictations.retentionDays) * 86_400 - 60)
        try FileManager.default.setAttributes([.modificationDate: weekAgo], ofItemAtPath: stale.path)

        UnfinishedDictations.migrateLegacyTakes(from: legacy, to: target, now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(take.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: primed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "an old take expires instead of moving")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(stale.lastPathComponent).path))
        XCTAssertEqual(UnfinishedDictations.scan(in: target, owned: [], now: Date()).count, 1)
    }

    // MARK: Pipeline

    private func pipelineSetUp(history: Bool) -> ScratchPreferences {
        let scratch = ScratchPreferences()
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = history
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false
        return scratch
    }

    private func enqueue(_ clip: URL, onRecovered: ((String) -> Void)? = nil) {
        DictationPipeline.shared.enqueue(
            tempURL: clip, startedAt: Date(), streamedFallback: "",
            context: DictationPipeline.ContextSnapshot(), modelOption: nil, onRecovered: onRecovered)
    }

    func testAFailedTranscriptionWithHistoryOffKeepsTheClip() async {
        let scratch = pipelineSetUp(history: false)
        defer { scratch.restore() }
        let pipeline = DictationPipeline.shared
        struct Boom: Error {}
        pipeline.transcribeOverride = { _, _, _ in throw Boom() }
        defer { pipeline.transcribeOverride = nil }
        let clip = write(takeName(secondsAgo: 5), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))

        enqueue(clip)
        await waitForDrain(pipeline)

        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(UnfinishedDictations.scan(in: directory, owned: [], now: Date()).count, 1)
    }

    func testASuccessfulTranscriptionWithHistoryOffRemovesTheClip() async {
        let scratch = pipelineSetUp(history: false)
        defer { scratch.restore() }
        let pipeline = DictationPipeline.shared
        pipeline.transcribeOverride = { _, _, _ in "hello" }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { pipeline.transcribeOverride = nil; pipeline.deliverOverride = nil }
        let clip = write(takeName(secondsAgo: 5), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))

        enqueue(clip)
        await waitForDrain(pipeline)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    func testRecoveringAClipHandsOverTheTextWithoutInsertingIt() async {
        let scratch = pipelineSetUp(history: false)
        defer { scratch.restore() }
        let pipeline = DictationPipeline.shared
        pipeline.transcribeOverride = { _, _, _ in "the lost words" }
        var inserted = false
        pipeline.deliverOverride = { _, _ in inserted = true; return .inserted }
        defer { pipeline.transcribeOverride = nil; pipeline.deliverOverride = nil }
        let clip = write(takeName(secondsAgo: 5), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: true))
        var recovered: [String] = []
        var clipWasThereWhenTextArrived = false

        enqueue(clip) { text in
            clipWasThereWhenTextArrived = FileManager.default.fileExists(atPath: clip.path)
            recovered.append(text)
        }
        XCTAssertTrue(pipeline.ownedClipNames.contains(clip.lastPathComponent),
                      "a clip being recovered is not offered again")
        await waitForDrain(pipeline)

        XCTAssertEqual(recovered, ["the lost words"])
        XCTAssertTrue(clipWasThereWhenTextArrived, "the audio goes only after the text is safe")
        XCTAssertFalse(inserted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    func testRecoveringAClipThatFailsAgainKeepsIt() async {
        let scratch = pipelineSetUp(history: false)
        defer { scratch.restore() }
        let pipeline = DictationPipeline.shared
        struct Boom: Error {}
        pipeline.transcribeOverride = { _, _, _ in throw Boom() }
        defer { pipeline.transcribeOverride = nil }
        let clip = write(takeName(secondsAgo: 5), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))
        var recovered: [String] = []

        enqueue(clip) { recovered.append($0) }
        await waitForDrain(pipeline)

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
    }

    func testDiscardingEverythingStillDeletesQueuedClips() async {
        let scratch = pipelineSetUp(history: false)
        defer { scratch.restore() }
        let pipeline = DictationPipeline.shared
        pipeline.transcribeOverride = { _, _, _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return "late"
        }
        defer { pipeline.transcribeOverride = nil }
        let first = write(takeName(secondsAgo: 5, id: "11111111"), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))
        let queued = write(takeName(secondsAgo: 4, id: "22222222"), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))

        enqueue(first)
        enqueue(queued)
        pipeline.discardEverything()
        await waitForDrain(pipeline)

        XCTAssertFalse(FileManager.default.fileExists(atPath: queued.path), "a dictation thrown away is not unfinished")
    }

    func testDiscardRemovesTheClipFromDiskAndList() {
        let url = write(takeName(secondsAgo: 5), WAVHeaderRepair.syntheticWAV(seconds: 1, staleSizes: false))
        let clip = UnfinishedClip(url: url, recordedAt: Date(), duration: 1)
        let model = UnfinishedDictations.shared
        model.seedForSnapshot(clips: [clip], recovered: [])

        model.discard(clip)

        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
