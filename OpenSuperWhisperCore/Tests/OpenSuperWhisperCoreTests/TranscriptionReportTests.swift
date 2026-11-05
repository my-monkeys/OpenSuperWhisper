import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// Reports (#168): what one keeps of its dictation, where it lives, and that it outlives the
/// recording it came from. Every store here is on an in-memory database; the audio goes under
/// the per-process test storage root.
@MainActor
final class TranscriptionReportTests: CoreTestCase {

    private var queue: DatabaseQueue!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        store = try RecordingStore(databaseQueue: queue)
        try? FileManager.default.removeItem(at: TranscriptionReport.reportsDirectory)
        try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: TranscriptionReport.reportsDirectory)
    }

    static func recording(raw: String? = "um so the cube cuttle cluster", final: String = "So the Kubernetes cluster.",
                          id: UUID = UUID()) -> Recording {
        Recording(id: id, timestamp: Date(timeIntervalSince1970: 1_760_000_000), fileName: "\(id.uuidString).wav",
                  transcription: final, duration: 4.5, status: .completed, progress: 1,
                  sourceAppName: "Slack", sourceWindowTitle: "#ops", sourceURL: "https://example.com/private",
                  modelUsed: "Parakeet v3", wasFallback: true, rawTranscription: raw)
    }

    static func report(for recording: Recording, problem: TranscriptionReport.Problem = .wrongWord,
                       createdAt: Date = Date(timeIntervalSince1970: 1_760_000_100)) -> TranscriptionReport {
        TranscriptionReport(createdAt: createdAt, recording: recording, problem: problem,
                            comment: "  It wrote cube cuttle.  \n", writtenAs: " cube cuttle ", shouldBe: "kubectl",
                            languageSetting: "en", appDetails: "OpenSuperWhisper 0.14.2 (65) · macOS 26.2 · Apple Silicon")
    }

    private func writeAudio(for recording: Recording, bytes: String = "RIFF fake audio") throws {
        try Data(bytes.utf8).write(to: recording.url)
    }

    // MARK: - The snapshot

    func testReportKeepsTheTextsModelAndTiming() {
        let recording = Self.recording()

        let report = Self.report(for: recording)

        XCTAssertEqual(report.recordingID, recording.id)
        XCTAssertEqual(report.recordedAt, recording.timestamp)
        XCTAssertEqual(report.finalText, "So the Kubernetes cluster.")
        XCTAssertEqual(report.rawText, "um so the cube cuttle cluster")
        XCTAssertEqual(report.distinctRawText, "um so the cube cuttle cluster")
        XCTAssertEqual(report.modelUsed, "Parakeet v3")
        XCTAssertTrue(report.wasFallback)
        XCTAssertEqual(report.duration, 4.5)
        XCTAssertEqual(report.comment, "It wrote cube cuttle.")
        XCTAssertEqual(report.writtenAs, "cube cuttle")
        XCTAssertEqual(report.shouldBe, "kubectl")
        XCTAssertNil(report.audioFileName)
    }

    /// Where it was dictated (app, window title, URL) is private and says nothing about the
    /// transcription, so a report has nowhere to keep it.
    func testReportLeavesOutWhereItWasDictated() throws {
        let report = Self.report(for: Self.recording())
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        XCTAssertFalse(encoded.contains("Slack"))
        XCTAssertFalse(encoded.contains("#ops"))
        XCTAssertFalse(encoded.contains("example.com"))
    }

    func testBlankWordFieldsAreNotKept() {
        let report = TranscriptionReport(recording: Self.recording(), problem: .other, comment: " ",
                                         writtenAs: "  ", shouldBe: "\n", languageSetting: nil, appDetails: "x")

        XCTAssertEqual(report.comment, "")
        XCTAssertNil(report.writtenAs)
        XCTAssertNil(report.shouldBe)
    }

    func testOnlyAWordOrANameConcernsTheDictionary() {
        XCTAssertEqual(TranscriptionReport.Problem.allCases.filter(\.concernsAWord), [.wrongWord, .wrongName])
    }

    // MARK: - Original text

    func testDistinctOriginalOnlyWhenTheTextsDiffer() {
        XCTAssertEqual(Self.recording().distinctOriginal, "um so the cube cuttle cluster")
        XCTAssertNil(Self.recording(raw: nil).distinctOriginal, "never kept")
        XCTAssertNil(Self.recording(raw: "   ").distinctOriginal, "nothing to offer")
        XCTAssertNil(Self.recording(raw: " Same text.\n", final: "Same text.").distinctOriginal,
                     "whitespace alone is no difference")
    }

    // MARK: - Schema

    func testReportsTableSchema() throws {
        let columns = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(transcription_reports)").map { row -> String in
                let dflt = (row["dflt_value"] as String?) ?? ""
                return "\(row["name"] as String)|\(row["type"] as String)|\(row["notnull"] as Int)|\(dflt)|\(row["pk"] as Int)"
            }
        }
        XCTAssertEqual(columns, [
            "id|TEXT|0||1",
            "createdAt|DATETIME|1||0",
            "recordingID|TEXT|1||0",
            "recordedAt|DATETIME|1||0",
            "problem|TEXT|1||0",
            "comment|TEXT|1|''|0",
            "writtenAs|TEXT|0||0",
            "shouldBe|TEXT|0||0",
            "finalText|TEXT|1||0",
            "rawText|TEXT|0||0",
            "modelUsed|TEXT|0||0",
            "wasFallback|BOOLEAN|1|0|0",
            "duration|DOUBLE|1||0",
            "languageSetting|TEXT|0||0",
            "appDetails|TEXT|1||0",
            "audioFileName|TEXT|0||0",
            "timingJSON|TEXT|0||0",
        ])
        let foreignKeys = try queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_list(transcription_reports)") }
        XCTAssertTrue(foreignKeys.isEmpty, "a report must not follow its recording out")
    }

    // MARK: - Store

    func testSavedReportRoundTripsWithItsOwnCopyOfTheAudio() async throws {
        let recording = Self.recording()
        try writeAudio(for: recording)
        let report = Self.report(for: recording)

        try await store.saveReport(report, audioFrom: recording.url)

        let saved = try await store.fetchReports()
        XCTAssertEqual(saved.count, 1)
        let fetched = try XCTUnwrap(saved.first)
        XCTAssertEqual(fetched.audioFileName, "\(report.id.uuidString).wav")
        var expected = report
        expected.audioFileName = fetched.audioFileName
        XCTAssertEqual(fetched, expected)
        let audio = try XCTUnwrap(fetched.audioURL)
        XCTAssertEqual(audio.deletingLastPathComponent().standardizedFileURL,
                       TranscriptionReport.reportsDirectory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: audio), Data("RIFF fake audio".utf8))
    }

    /// Retention and the history's delete buttons remove the recording and its clip; the
    /// report the user chose to keep stays whole.
    func testReportOutlivesItsRecording() async throws {
        let recording = Self.recording()
        try writeAudio(for: recording)
        try await queue.write { db in try recording.insert(db) }
        try await store.saveReport(Self.report(for: recording), audioFrom: recording.url)

        try FileManager.default.removeItem(at: recording.url)
        _ = try await queue.write { db in try recording.delete(db) }

        let reports = try await store.fetchReports()
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.finalText, recording.transcription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(report.audioURL).path))
    }

    func testReportWithoutAudioIsStillSaved() async throws {
        let recording = Self.recording()

        try await store.saveReport(Self.report(for: recording), audioFrom: recording.url)

        let reports = try await store.fetchReports()
        let report = try XCTUnwrap(reports.first)
        XCTAssertNil(report.audioFileName)
    }

    func testDeletingAReportRemovesItsAudioOnly() async throws {
        let recording = Self.recording()
        try writeAudio(for: recording)
        try await store.saveReport(Self.report(for: recording), audioFrom: recording.url)
        let reports = try await store.fetchReports()
        let report = try XCTUnwrap(reports.first)

        try await store.deleteReport(report)

        let remaining = try await store.fetchReports()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(report.audioURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.url.path), "the recording keeps its clip")
    }

    func testReportsComeNewestFirstAndAreCounted() async throws {
        let older = Self.report(for: Self.recording(), createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Self.report(for: Self.recording(), createdAt: Date(timeIntervalSince1970: 2_000))
        try await store.saveReport(older, audioFrom: nil)
        try await store.saveReport(newer, audioFrom: nil)

        let ids = try await store.fetchReports().map(\.id)
        let count = await store.countReports()
        XCTAssertEqual(ids, [newer.id, older.id])
        XCTAssertEqual(count, 2)
    }

    /// The copy is made before the row; a row that cannot be written takes its copy with it.
    func testFailedSaveLeavesNoAudioBehind() async throws {
        let recording = Self.recording()
        try writeAudio(for: recording)
        try await queue.write { db in try db.drop(table: TranscriptionReport.databaseTableName) }

        do {
            try await store.saveReport(Self.report(for: recording), audioFrom: recording.url)
            XCTFail("the insert should have failed")
        } catch {}

        let left = (try? FileManager.default.contentsOfDirectory(atPath: TranscriptionReport.reportsDirectory.path)) ?? []
        XCTAssertEqual(left, [])
    }
}
