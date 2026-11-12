import Foundation
import GRDB

/// A dictation the user flagged as badly transcribed, saved on this Mac with everything needed
/// to look into it later: what went wrong, the texts, the model, and a copy of the audio (#168).
///
/// A report is a snapshot rather than a pointer to its recording. The history's retention
/// policy and its delete buttons remove recordings and their audio; a report the user chose to
/// keep must not vanish with them, so it carries its own texts and its own copy of the clip.
public struct TranscriptionReport: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {

    /// What the user says went wrong. Stored by raw value, so cases are never renamed.
    public enum Problem: String, Codable, CaseIterable, Sendable {
        case wrongWord, wrongName, wrongLanguage, cleanupChangedMeaning, other

        /// A word or a name: the cases where the dictionary can fix the next dictation.
        public var concernsAWord: Bool { self == .wrongWord || self == .wrongName }
    }

    public let id: UUID
    public let createdAt: Date
    /// The recording it was made from, while that still exists. Never joined on: see above.
    public let recordingID: UUID
    public let recordedAt: Date
    public var problem: Problem
    public var comment: String
    /// For a wrong word or name: what the model wrote, and what it should have written.
    public var writtenAs: String?
    public var shouldBe: String?
    /// The whole text the dictation should have produced, as the user corrected it. Without it a
    /// report only says that something was wrong, and the same audio gives the same text on the
    /// maintainer's Mac. Nil on reports made before it was asked for, and for "Something else".
    public var expectedText: String?
    public let finalText: String
    /// The engine's text before the cleanup (`Recording.rawTranscription`), when the history kept it.
    public let rawText: String?
    public let modelUsed: String?
    public let wasFallback: Bool
    public let duration: TimeInterval
    /// The language setting when the report was made. The recording does not keep the one it
    /// was dictated with, and for a wrong-language report this is the next best thing.
    public let languageSetting: String?
    /// "OpenSuperWhisper 0.14.2 (65) · macOS 26.2 · Apple Silicon", when the report was made.
    public let appDetails: String
    /// The copy of the audio under `reportsDirectory`, nil when the dictation had none.
    public var audioFileName: String?
    /// Where the dictation's time went (#262), copied from the recording at save time. A report
    /// outlives its recording, so a pointer would lose the measurement exactly when a slow
    /// dictation is being reported. Nil on a row that was never measured.
    public let timingJSON: String?

    /// The decoded measurement, read from the column every time so the two can never disagree.
    public var timing: DictationTiming? { DictationTiming.decode(timingJSON) }

    /// How the dictation ended, as far as the report can know it (#262). `.noInsertion` is the
    /// conservative catch-all: a completed row handed to an agent, recovered from `unfinished/`,
    /// or left on the clipboard for a manual paste is not distinguishable here, and the report
    /// does not guess. Nil when even that much is unknown: a row with no measurement at all (an
    /// import, a rerun, or a row older than v11), or a blob that never reached its terminal stamp
    /// (the post-delivery UPDATE failed, or the report was saved before it landed).
    public enum Ending: String, Codable, Sendable {
        case insertion, noInsertion, failure
    }

    public let ending: Ending?

    public init(id: UUID = UUID(), createdAt: Date = Date(), recording: Recording,
                problem: Problem, comment: String = "", writtenAs: String? = nil, shouldBe: String? = nil,
                expectedText: String? = nil, languageSetting: String?, appDetails: String) {
        self.id = id
        self.createdAt = createdAt
        self.recordingID = recording.id
        self.recordedAt = recording.timestamp
        self.problem = problem
        self.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        self.writtenAs = Self.nonBlank(writtenAs)
        self.shouldBe = Self.nonBlank(shouldBe)
        self.expectedText = Self.nonBlank(expectedText)
        self.finalText = recording.transcription
        self.rawText = recording.rawTranscription
        self.modelUsed = recording.modelUsed
        self.wasFallback = recording.wasFallback
        self.duration = recording.duration
        self.languageSetting = languageSetting
        self.appDetails = appDetails
        self.timingJSON = recording.timingJSON
        self.ending = Self.ending(for: recording)
        self.audioFileName = nil
    }

    private static func ending(for recording: Recording) -> Ending? {
        if recording.status == .failed { return .failure }
        // A blob without its terminal stamp cannot support even "no insertion": an insertion may
        // have happened and only the record of it been lost.
        guard let timing = recording.timing, timing.totalMs != nil else { return nil }
        return timing.insertMs != nil ? .insertion : .noInsertion
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static let databaseTableName = "transcription_reports"

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    /// Migration `v7_add_transcription_reports`. No foreign key to `recordings`, on purpose: a
    /// cascade would delete the report with its recording, a restriction would block retention.
    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("createdAt", .datetime).notNull().indexed()
            t.column("recordingID", .text).notNull()
            t.column("recordedAt", .datetime).notNull()
            t.column("problem", .text).notNull()
            t.column("comment", .text).notNull().defaults(to: "")
            t.column("writtenAs", .text)
            t.column("shouldBe", .text)
            t.column("finalText", .text).notNull()
            t.column("rawText", .text)
            t.column("modelUsed", .text)
            t.column("wasFallback", .boolean).notNull().defaults(to: false)
            t.column("duration", .double).notNull()
            t.column("languageSetting", .text)
            t.column("appDetails", .text).notNull()
            t.column("audioFileName", .text)
        }
    }

    // MARK: - Audio

    public static var reportsDirectory: URL {
        CoreAccess.storageRoot.appendingPathComponent("reports", isDirectory: true)
    }

    public var audioURL: URL? {
        audioFileName.map { Self.reportsDirectory.appendingPathComponent($0) }
    }
}

extension Recording {
    /// The engine's text when it says something other than the text the user got, else nil.
    /// Whitespace alone is not a difference worth offering to undo.
    public var distinctOriginal: String? {
        TranscriptionReport.distinct(rawTranscription, from: transcription)
    }
}

extension TranscriptionReport {
    /// The engine's text when it differs from the final one, as on the recording it came from.
    public var distinctRawText: String? {
        Self.distinct(rawText, from: finalText)
    }

    static func distinct(_ raw: String?, from final: String) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != final.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return raw
    }
}

// MARK: - Store

extension RecordingStore {
    public static let reportsDidUpdateNotification = Notification.Name("RecordingStore.reportsDidUpdate")

    /// Saves the report with its own copy of the recording's audio, when there is one. The copy
    /// comes first, so a row never points at a file that is not there; a failed insert removes it.
    public nonisolated func saveReport(_ report: TranscriptionReport, audioFrom source: URL?) async throws {
        var report = report
        let fileManager = FileManager.default
        if let source, fileManager.fileExists(atPath: source.path) {
            let directory = TranscriptionReport.reportsDirectory
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(report.id.uuidString).\(source.pathExtension.isEmpty ? "wav" : source.pathExtension)"
            let destination = directory.appendingPathComponent(fileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            report.audioFileName = fileName
        }
        do {
            try await dbQueue.write { [report] db in try report.insert(db) }
        } catch {
            if let url = report.audioURL { try? fileManager.removeItem(at: url) }
            throw error
        }
        await Self.postReportsDidUpdate()
    }

    /// Every report, newest first.
    public nonisolated func fetchReports() async throws -> [TranscriptionReport] {
        try await dbQueue.read { db in
            try TranscriptionReport.order(TranscriptionReport.Columns.createdAt.desc).fetchAll(db)
        }
    }

    public nonisolated func countReports() async -> Int {
        (try? await dbQueue.read { db in try TranscriptionReport.fetchCount(db) }) ?? 0
    }

    /// Removes the report and its copy of the audio. The recording it came from is untouched.
    public nonisolated func deleteReport(_ report: TranscriptionReport) async throws {
        _ = try await dbQueue.write { db in try report.delete(db) }
        if let url = report.audioURL { try? FileManager.default.removeItem(at: url) }
        await Self.postReportsDidUpdate()
    }

    @MainActor
    private static func postReportsDidUpdate() {
        NotificationCenter.default.post(name: reportsDidUpdateNotification, object: nil)
    }
}
