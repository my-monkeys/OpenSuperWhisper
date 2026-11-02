import Foundation
import GRDB

public enum RecordingStatus: String, Codable, Sendable {
    case pending
    case converting
    case transcribing
    case completed
    case failed
}

/// Which recordings the history shows: everything, live dictations, imported files, or failures.
public enum RecordingFilter: String, CaseIterable, Sendable {
    case all, dictations, files, errors
}

public struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let fileName: String
    public var transcription: String
    public let duration: TimeInterval
    public var status: RecordingStatus
    public var progress: Float
    public var sourceFileURL: String?
    // Where the dictation happened (captured at record-start). All optional with
    // nil defaults so existing Recording(...) call sites (file imports, etc.) and
    // older recordings keep working.
    public var sourceAppName: String? = nil
    public var sourceWindowTitle: String? = nil
    public var sourceURL: String? = nil
    /// Display name of the model used for this transcription (e.g. "whisper-large-v3").
    public var modelUsed: String? = nil
    /// True when this transcription came from the remote engine's local fallback (the
    /// server was unreachable). The history row tints the model label to flag it.
    public var wasFallback: Bool = false
    /// The text as the engine handed it back (its dictionary rules already applied), before the
    /// filler words came out and the AI cleanup ran. Kept so a cleanup that rewrote too much can
    /// be undone from the history, and so a report can show both (#168). Kept even when nothing
    /// changed it, so "same text" and "never kept" stay apart. Imports and reruns store their own
    /// text here, since it is the engine's; nil means a row older than the column (or a failure).
    public var rawTranscription: String? = nil
    /// The writing style AI cleanup wrote this text in, by name, as it was called then (#160).
    /// Nil when no style shaped it: Raw, cleanup off, or a row older than the column.
    public var styleUsed: String? = nil
    /// The model of the AI cleanup pass that ran, or was attempted, on this text (#266). Nil when
    /// no pass was due, and on a row older than the column.
    public var cleanupModel: String? = nil
    /// Why that pass failed and the engine's text was used instead (#264). Set only alongside
    /// `cleanupModel`; nil when the pass worked.
    public var cleanupError: String? = nil

    public var isRegeneration: Bool = false

    public init(id: UUID, timestamp: Date, fileName: String, transcription: String,
                duration: TimeInterval, status: RecordingStatus, progress: Float,
                sourceFileURL: String? = nil, sourceAppName: String? = nil,
                sourceWindowTitle: String? = nil, sourceURL: String? = nil,
                modelUsed: String? = nil, wasFallback: Bool = false, rawTranscription: String? = nil,
                styleUsed: String? = nil, cleanupModel: String? = nil, cleanupError: String? = nil,
                isRegeneration: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.transcription = transcription
        self.duration = duration
        self.status = status
        self.progress = progress
        self.sourceFileURL = sourceFileURL
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.sourceURL = sourceURL
        self.modelUsed = modelUsed
        self.wasFallback = wasFallback
        self.rawTranscription = rawTranscription
        self.styleUsed = styleUsed
        self.cleanupModel = cleanupModel
        self.cleanupError = cleanupError
        self.isRegeneration = isRegeneration
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL
        case sourceAppName, sourceWindowTitle, sourceURL, modelUsed, wasFallback, rawTranscription
        case styleUsed, cleanupModel, cleanupError
    }

    public static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id &&
               lhs.status == rhs.status &&
               lhs.progress == rhs.progress &&
               lhs.transcription == rhs.transcription &&
               lhs.rawTranscription == rhs.rawTranscription &&
               lhs.styleUsed == rhs.styleUsed &&
               lhs.cleanupModel == rhs.cleanupModel &&
               lhs.cleanupError == rhs.cleanupError &&
               lhs.isRegeneration == rhs.isRegeneration
    }

    public static var recordingsDirectory: URL {
        recordingsDirectory(in: CoreAccess.storageRoot)
    }

    static func recordingsDirectory(in root: URL) -> URL {
        root.appendingPathComponent("recordings")
    }

    public var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }
    
    public var isPending: Bool {
        status == .pending || status == .converting || status == .transcribing
    }
    
    public var sourceFileName: String? {
        guard let sourceFileURL = sourceFileURL else { return nil }
        return URL(fileURLWithPath: sourceFileURL).lastPathComponent
    }

    public static let databaseTableName = "recordings"

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
        static let status = Column(CodingKeys.status)
        static let progress = Column(CodingKeys.progress)
        static let sourceFileURL = Column(CodingKeys.sourceFileURL)
        static let sourceAppName = Column(CodingKeys.sourceAppName)
        static let sourceWindowTitle = Column(CodingKeys.sourceWindowTitle)
        static let sourceURL = Column(CodingKeys.sourceURL)
        static let modelUsed = Column(CodingKeys.modelUsed)
        static let wasFallback = Column(CodingKeys.wasFallback)
        static let rawTranscription = Column(CodingKeys.rawTranscription)
        static let cleanupModel = Column(CodingKeys.cleanupModel)
        static let cleanupError = Column(CodingKeys.cleanupError)
    }
}

@MainActor
public class RecordingStore: ObservableObject {
    public static let shared = RecordingStore(storageRoot: CoreAccess.storageRoot)

    @Published private(set) var recordings: [Recording] = []
    /// Internal rather than private so the reports (TranscriptionReport.swift) share the file.
    let dbQueue: DatabaseQueue
    private var retentionTimer: Timer?

    init(storageRoot appDirectory: URL) {
        let dbPath = Self.databaseURL(in: appDirectory)

        do {
            try FileManager.default.createDirectory(
                at: appDirectory, withIntermediateDirectories: true)
            dbQueue = try Self.openDatabase(at: dbPath)
            try setupDatabase()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    /// A store on a database the caller opened, so the migrations and the record mapping can be
    /// exercised on a scratch or fixture file. The app only ever uses `shared`.
    init(databaseQueue: DatabaseQueue) throws {
        dbQueue = databaseQueue
        try setupDatabase()
    }

    /// How the app opens its database file: GRDB's default configuration, so the rollback
    /// journal SQLite defaults to. Internal so a test can pin what that leaves on disk.
    nonisolated static func openDatabase(at url: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: url.path)
    }

    nonisolated static func databaseURL(in root: URL) -> URL {
        root.appendingPathComponent("recordings.sqlite")
    }

    private nonisolated func setupDatabase() throws {
        try Self.makeMigrator().migrate(dbQueue)
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }
    
    public nonisolated func fetchRecordings(limit: Int, offset: Int) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func getPendingRecordings() -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to get pending recordings: \(error)")
            return []
        }
    }

    func getNextPendingRecording() -> Recording? {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .limit(1)
                    .fetchOne(db)
            }
        } catch {
            print("Failed to get next pending recording: \(error)")
            return nil
        }
    }

    public static let recordingsDidUpdateNotification = Notification.Name("RecordingStore.recordingsDidUpdate")

    public func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await MainActor.run {
                    RecordingsDiskUsage.shared.recordingSaved(at: recording.url)
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
                // Keep the store within the retention limit right after a new
                // recording lands, so the count behaves like a fixed-size buffer
                // instead of overshooting until the next periodic check.
                await enforceRetentionPolicy()
            } catch {
                print("Failed to add recording: \(error)")
            }
        }
    }
    
    func addRecordingSync(_ recording: Recording) async throws {
        try await insertRecording(recording)
        await MainActor.run {
            RecordingsDiskUsage.shared.recordingSaved(at: recording.url)
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.insert(db)
        }
    }
    
    func updateRecording(_ recording: Recording) {
        Task {
            do {
                try await updateRecordingInDB(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to update recording: \(error)")
            }
        }
    }
    
    /// Replaces a row's text with the same dictation rewritten in another writing style, from
    /// the history (#160). The engine's original stays as it was. The pass that just ran replaces
    /// the outcome the row kept from the previous one.
    public func restyle(_ recording: Recording, transcription: String, styleUsed: String?,
                        cleanup: CleanupOutcome) async throws {
        var updated = recording
        updated.transcription = transcription
        updated.styleUsed = styleUsed
        updated.cleanupModel = cleanup.model
        updated.cleanupError = cleanup.failureReason
        try await updateRecordingSync(updated)
    }

    func updateRecordingSync(_ recording: Recording) async throws {
        try await updateRecordingInDB(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    func updateRecordingProgressOnly(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus) {
        Task {
            await updateRecordingProgressOnlySync(id, transcription: transcription, progress: progress, status: status)
        }
    }
    
    public static let recordingProgressDidUpdateNotification = Notification.Name("RecordingStore.recordingProgressDidUpdate")
    
    /// - Parameter rawTranscription: replaces the kept original when given. An import or a rerun
    ///   passes its own text, which is the engine's: the original kept from a dictation no
    ///   longer goes with the new text, and nil stays reserved for rows older than the column.
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil, modelUsed: String? = nil, wasFallback: Bool? = nil, rawTranscription: String? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                var assignments = [
                    Recording.Columns.transcription.set(to: transcription),
                    Recording.Columns.progress.set(to: progress),
                    Recording.Columns.status.set(to: status.rawValue)
                ]
                if let modelUsed {
                    assignments.append(Recording.Columns.modelUsed.set(to: modelUsed))
                }
                if let wasFallback {
                    assignments.append(Recording.Columns.wasFallback.set(to: wasFallback))
                }
                if let rawTranscription {
                    assignments.append(Recording.Columns.rawTranscription.set(to: rawTranscription))
                    // The new text is the engine's own, with no cleanup pass behind it.
                    assignments.append(Recording.Columns.cleanupModel.set(to: nil))
                    assignments.append(Recording.Columns.cleanupError.set(to: nil))
                }
                return try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, assignments)
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                var updated = recordings[index]
                updated.transcription = transcription
                updated.progress = progress
                updated.status = status
                if let isRegeneration = isRegeneration {
                    updated.isRegeneration = isRegeneration
                }
                if let modelUsed {
                    updated.modelUsed = modelUsed
                }
                if let wasFallback {
                    updated.wasFallback = wasFallback
                }
                if let rawTranscription {
                    updated.rawTranscription = rawTranscription
                    updated.cleanupModel = nil
                    updated.cleanupError = nil
                }
                recordings[index] = updated
            }

            var userInfo: [String: Any] = [
                "id": id,
                "transcription": transcription,
                "progress": progress,
                "status": status
            ]
            if let isRegeneration = isRegeneration {
                userInfo["isRegeneration"] = isRegeneration
            }
            if let modelUsed {
                userInfo["modelUsed"] = modelUsed
            }
            if let wasFallback {
                userInfo["wasFallback"] = wasFallback
            }
            if let rawTranscription {
                userInfo["rawTranscription"] = rawTranscription
            }

            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
            }
        } catch {
            print("Failed to update recording progress: \(error)")
        }
    }

    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                var updated = recordings[index]
                updated.progress = progress
                updated.status = status
                if let isRegeneration = isRegeneration {
                    updated.isRegeneration = isRegeneration
                }
                recordings[index] = updated
            }
            
            var userInfo: [String: Any] = [
                "id": id,
                "progress": progress,
                "status": status
            ]
            if let isRegeneration = isRegeneration {
                userInfo["isRegeneration"] = isRegeneration
            }
            
            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
            }
        } catch {
            print("Failed to update recording status: \(error)")
        }
    }

    private nonisolated func updateRecordingInDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.update(db)
        }
    }

    public func deleteRecording(_ recording: Recording) {
        if recording.isPending {
            TranscriptionQueue.shared.cancelRecording(recording.id)
        }
        
        Task {
            do {
                try await deleteRecordingFromDB(recording)
                let removed = RecordingsDiskUsage.measure([recording.url])
                try? FileManager.default.removeItem(at: recording.url)
                await MainActor.run {
                    RecordingsDiskUsage.shared.recordingsRemoved(removed)
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete recording: \(error)")
            }
        }
    }
    
    private nonisolated func deleteRecordingFromDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            _ = try recording.delete(db)
        }
    }

    public func deleteAllRecordings() {
        Task {
            do {
                let allRecordings = try await fetchAllRecordings()
                for recording in allRecordings {
                    try? FileManager.default.removeItem(at: recording.url)
                }
                try await deleteAllRecordingsFromDB()
                await MainActor.run {
                    RecordingsDiskUsage.shared.allRecordingsRemoved()
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete all recordings: \(error)")
            }
        }
    }
    
    private nonisolated func deleteAllRecordingsFromDB() async throws {
        try await dbQueue.write { db in
            _ = try Recording.deleteAll(db)
        }
    }

    // MARK: - Retention policy

    /// Applies the user's retention policy, deleting recordings that exceed the
    /// configured maximum count and/or that are older than the configured age.
    /// In-progress recordings (pending / converting / transcribing) are never
    /// removed. Returns the number of recordings that were deleted.
    @discardableResult
    public func enforceRetentionPolicy() async -> Int {
        let policy = RetentionPolicy()
        guard policy.isActive else { return 0 }

        let deleted: [Recording]
        do {
            deleted = try await deleteExpiredRecordings(policy: policy)
        } catch {
            print("Failed to enforce retention policy: \(error)")
            return 0
        }

        guard !deleted.isEmpty else { return 0 }

        // Remove the stored audio files off the main actor.
        let removed = await Task.detached(priority: .utility) {
            let sizes = RecordingsDiskUsage.measure(deleted.map(\.url))
            for recording in deleted {
                try? FileManager.default.removeItem(at: recording.url)
            }
            return sizes
        }.value
        RecordingsDiskUsage.shared.recordingsRemoved(removed)

        let deletedIds = Set(deleted.map { $0.id })
        recordings.removeAll { deletedIds.contains($0.id) }

        NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        return deleted.count
    }

    /// Interval between periodic age-based retention checks.
    private static let retentionCheckInterval: TimeInterval = 60

    /// Starts a periodic timer that re-applies the retention policy.
    ///
    /// This is needed for the age-based limit: recordings expire as real time
    /// passes, even when no new recordings are added. The count-based limit does
    /// not need this — it is enforced whenever recordings are added (when the
    /// transcription queue drains). The periodic check therefore only does work
    /// while the age policy is enabled.
    public func startRetentionScheduler() {
        // Run once immediately so expired recordings are cleaned up on launch.
        Task { await enforceRetentionPolicy() }

        retentionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.retentionCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, CoreAccess.preferences.retentionMaxAgeEnabled else { return }
                await self.enforceRetentionPolicy()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    private nonisolated func deleteExpiredRecordings(policy: RetentionPolicy) async throws -> [Recording] {
        try await dbQueue.write { db in
            let activeStatuses = [
                RecordingStatus.pending.rawValue,
                RecordingStatus.converting.rawValue,
                RecordingStatus.transcribing.rawValue
            ]

            var toDelete: [UUID: Recording] = [:]

            // Age-based expiration: anything older than the cutoff date.
            if let cutoff = policy.ageCutoffDate() {
                let expired = try Recording
                    .filter(!activeStatuses.contains(Recording.Columns.status))
                    .filter(Recording.Columns.timestamp < cutoff)
                    .fetchAll(db)
                for recording in expired {
                    toDelete[recording.id] = recording
                }
            }

            // Count-based expiration: keep the newest `maxCount`, drop the rest.
            if policy.maxCountEnabled, policy.maxCount > 0 {
                let finished = try Recording
                    .filter(!activeStatuses.contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
                if finished.count > policy.maxCount {
                    for recording in finished[policy.maxCount...] {
                        toDelete[recording.id] = recording
                    }
                }
            }

            for recording in toDelete.values {
                _ = try recording.delete(db)
            }

            return Array(toDelete.values)
        }
    }

    func searchRecordings(query: String) -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .limit(100)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
    
    /// One page of the history narrowed by kind and, when `query` is not empty, by text.
    public nonisolated func fetchRecordings(filter: RecordingFilter, query: String = "",
                                            limit: Int, offset: Int) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Self.request(filter: filter, query: query)
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// How many recordings the filter matches, over the whole history rather than a loaded page.
    public nonisolated func countRecordings(filter: RecordingFilter) async -> Int {
        (try? await dbQueue.read { db in try Self.request(filter: filter, query: "").fetchCount(db) }) ?? 0
    }

    private nonisolated static func request(filter: RecordingFilter, query: String) -> QueryInterfaceRequest<Recording> {
        var request = Recording.all()
        switch filter {
        case .all: break
        case .dictations: request = request.filter(Recording.Columns.sourceFileURL == nil)
        case .files: request = request.filter(Recording.Columns.sourceFileURL != nil)
        case .errors: request = request.filter(Recording.Columns.status == RecordingStatus.failed.rawValue)
        }
        if !query.isEmpty {
            request = request.filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
        }
        return request
    }

    public nonisolated func searchRecordingsAsync(query: String, limit: Int = 100, offset: Int = 0) async -> [Recording] {
        do {
            return try await dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
}
