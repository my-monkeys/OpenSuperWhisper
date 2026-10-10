import GRDB
import XCTest

@testable import OpenSuperWhisper

/// The rows inside `Fixtures/recordings-0.13.3.sqlite`. The file was written once, before any
/// code moved, by `RecordingStore(databaseQueue:)` on a new file (0.13.3's migrations) followed
/// by `Recording.insert` for each row, and is committed as is: the tests compare against these
/// literals, never against a database the current build just made.
enum RecordingMigrationFixture {
    static func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    static let rows: [Recording] = [
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                  timestamp: date(1_760_000_000.125), fileName: "pending.wav", transcription: "",
                  duration: 1.5, status: .pending, progress: 0, sourceFileURL: nil),
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                  timestamp: date(1_760_000_100.25), fileName: "converting.wav", transcription: "",
                  duration: 12.75, status: .converting, progress: 0.25,
                  sourceFileURL: "/Users/someone/Desktop/interview.m4a"),
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                  timestamp: date(1_760_000_200.5), fileName: "transcribing.wav", transcription: "Partial text",
                  duration: 30, status: .transcribing, progress: 0.5, sourceFileURL: nil,
                  modelUsed: "Parakeet v3"),
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                  timestamp: date(1_760_000_300), fileName: "completed.wav",
                  transcription: "Héllo wörld, ça marche ? 日本語もOK. \"quoted\"\nsecond line",
                  duration: 4.25, status: .completed, progress: 1, sourceFileURL: nil,
                  sourceAppName: "Slack", sourceWindowTitle: "#general", sourceURL: "https://example.com/a?b=c",
                  modelUsed: "ggml-large-v3-turbo", wasFallback: false),
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
                  timestamp: date(1_760_000_400.875), fileName: "fallback.wav", transcription: "From the fallback",
                  duration: 2, status: .completed, progress: 1, sourceFileURL: nil,
                  sourceAppName: "Terminal", modelUsed: "Parakeet v2", wasFallback: true),
        Recording(id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
                  timestamp: date(1_760_000_500), fileName: "failed.wav", transcription: "Error: server unreachable",
                  duration: 0.5, status: .failed, progress: 0, sourceFileURL: "/tmp/dropped.mp3"),
    ]
}

/// The recordings database outlives every build: users have thousands of rows written by older
/// versions, and GRDB decides what to run from the migration identifiers stored in the file. A
/// renamed identifier reruns a migration on a table that already has its columns; a reordered or
/// dropped one leaves a schema the record mapping no longer fits. Both happen at launch, before
/// anything is shown. These tests pin the identifiers, the schema they produce, and that a
/// database written by 0.13.3 opens unchanged and maps back to the same values.
@MainActor
final class RecordingMigrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Identifiers

    func testMigrationIdentifiersInOrder() {
        XCTAssertEqual(RecordingStore.makeMigrator().migrations,
                       ["v1", "v2_add_status", "v3_add_source_context", "v4_add_model_used", "v5_add_was_fallback"])
    }

    // MARK: - Schema

    func testFreshDatabaseGetsTheFullSchema() throws {
        let queue = try DatabaseQueue()
        _ = try RecordingStore(databaseQueue: queue)

        XCTAssertEqual(try Self.columns(queue), Self.expectedColumns)
        XCTAssertEqual(try Self.indexes(queue), Self.expectedIndexes)
        XCTAssertEqual(try Self.tableSQL(queue), Self.expectedTableSQL)
        XCTAssertEqual(try Self.appliedMigrations(queue), RecordingStore.makeMigrator().migrations)
    }

    func testRerunningTheMigrationsIsANoOp() throws {
        let queue = try DatabaseQueue()
        _ = try RecordingStore(databaseQueue: queue)
        try queue.write { db in try RecordingMigrationFixture.rows[3].insert(db) }
        let before = try Self.dump(queue)

        try RecordingStore.makeMigrator().migrate(queue)
        _ = try RecordingStore(databaseQueue: queue)

        XCTAssertEqual(try Self.dump(queue), before)
    }

    // MARK: - Opening the file

    /// The app opens its file with GRDB's default configuration: SQLite's rollback journal, which
    /// leaves nothing next to the database between writes. Switching to WAL, or adding a
    /// `prepareDatabase`, would change the files on every user's disk (WAL also persists in the
    /// file itself, so an older build would then open it in WAL too).
    func testDatabaseOpensWithTheRollbackJournal() throws {
        let url = RecordingStore.databaseURL(in: directory)
        let queue = try RecordingStore.openDatabase(at: url)
        _ = try RecordingStore(databaseQueue: queue)
        try queue.write { db in try RecordingMigrationFixture.rows[0].insert(db) }

        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "delete")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(siblings, ["recordings.sqlite"])
    }

    /// The 0.13.3 file is in the same mode, so the comparison above is with what users have.
    func testDatabaseFrom0133UsesTheRollbackJournal() throws {
        let queue = try RecordingStore.openDatabase(at: copyOfFixture())
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "delete")
    }

    // MARK: - 0.13.3 fixture

    /// From the test bundle, where the synchronized group copies it, so the tests do not depend
    /// on the source checkout sitting where it was compiled.
    private func copyOfFixture() throws -> URL {
        let fixture = try XCTUnwrap(Bundle(for: RecordingMigrationTests.self)
            .url(forResource: "recordings-0.13.3", withExtension: "sqlite"))
        let copy = directory.appendingPathComponent("recordings.sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    /// Opening it is what every user's launch does today: nothing may be migrated, rewritten or
    /// lost, whatever the status of the row.
    func testDatabaseFrom0133OpensUnchanged() throws {
        let queue = try RecordingStore.openDatabase(at: copyOfFixture())
        let before = try Self.dump(queue)
        XCTAssertEqual(try Self.appliedMigrations(queue), RecordingStore.makeMigrator().migrations)

        _ = try RecordingStore(databaseQueue: queue)

        XCTAssertEqual(try Self.dump(queue), before)
        XCTAssertEqual(try Self.columns(queue), Self.expectedColumns)
        XCTAssertEqual(try Self.indexes(queue), Self.expectedIndexes)
    }

    func testDatabaseFrom0133MapsBackToTheSameRecordings() async throws {
        let store = try RecordingStore(databaseQueue: DatabaseQueue(path: copyOfFixture().path))

        let fetched = try await store.fetchRecordings(limit: 100, offset: 0)

        // Newest first, which is the order the history list relies on.
        let expected = RecordingMigrationFixture.rows.sorted { $0.timestamp > $1.timestamp }
        XCTAssertEqual(fetched.map(\.id), expected.map(\.id))
        for (row, want) in zip(fetched, expected) {
            Self.assertSameColumns(row, want)
        }
    }

    /// The raw values in the fixture, so a change to how a column is encoded (dates as text in
    /// UTC with milliseconds, UUIDs as 16-byte blobs, booleans as integers) is caught even if
    /// the round trip still works for new rows.
    func testDatabaseFrom0133StoresColumnsInTheirCurrentEncoding() throws {
        let queue = try DatabaseQueue(path: copyOfFixture().path)
        let row = try XCTUnwrap(queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM recordings WHERE fileName = 'fallback.wav'")
        })
        // A 16-byte blob in a column declared TEXT: GRDB's UUID encoding, not the declared type.
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
        XCTAssertEqual(row["id"] as Data?, withUnsafeBytes(of: id.uuid) { Data($0) })
        XCTAssertEqual(row["timestamp"] as String?, "2025-10-09 09:00:00.875")
        XCTAssertEqual(row["status"] as String?, "completed")
        XCTAssertEqual(row["progress"] as Double?, 1.0)
        XCTAssertEqual(row["wasFallback"] as Int64?, 1)
        XCTAssertEqual(row["duration"] as Double?, 2.0)
        XCTAssertNil(row["sourceURL"] as String?)
    }

    // MARK: - Round trip

    /// Every persisted column survives a write and a read. `isRegeneration` is not a column, so
    /// it always comes back false.
    func testEveryColumnRoundTrips() async throws {
        let queue = try DatabaseQueue()
        let store = try RecordingStore(databaseQueue: queue)
        var recording = RecordingMigrationFixture.rows[3]
        recording.isRegeneration = true
        try await queue.write { db in try recording.insert(db) }

        let fetched = try await store.fetchRecordings(limit: 1, offset: 0)

        let row = try XCTUnwrap(fetched.first)
        recording.isRegeneration = false
        Self.assertSameColumns(row, recording)
        XCTAssertFalse(row.isRegeneration)
    }

    // MARK: - Legacy v1 database

    /// A database from before the status column: every later migration runs, the rows survive,
    /// and the new columns take their defaults (completed, progress 1, no fallback, nulls).
    func testV1DatabaseUpgradesWithRowsPreserved() throws {
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("v1.sqlite").path)
        try RecordingStore.makeMigrator().migrate(queue, upTo: "v1")
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
        try queue.write { db in
            // The id goes in as GRDB binds a UUID, the way the builds of that era wrote it.
            try db.execute(sql: """
                INSERT INTO recordings (id, timestamp, fileName, transcription, duration)
                VALUES (?, '2024-03-01 10:00:00.000', 'old.wav', 'Old text', 3.5)
                """, arguments: [id])
        }
        XCTAssertEqual(try Self.appliedMigrations(queue), ["v1"])

        let store = try RecordingStore(databaseQueue: queue)

        XCTAssertEqual(try Self.appliedMigrations(queue), RecordingStore.makeMigrator().migrations)
        XCTAssertEqual(try Self.columns(queue), Self.expectedColumns)
        XCTAssertEqual(try Self.indexes(queue), Self.expectedIndexes)
        XCTAssertEqual(try Self.tableSQL(queue), Self.expectedTableSQL)

        XCTAssertEqual(store.getPendingRecordings().count, 0, "the default status is completed")
        let upgraded = try XCTUnwrap(fetchAll(queue).first)
        Self.assertSameColumns(upgraded, Recording(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_709_287_200), fileName: "old.wav",
            transcription: "Old text", duration: 3.5, status: .completed, progress: 1,
            sourceFileURL: nil, sourceAppName: nil, sourceWindowTitle: nil, sourceURL: nil,
            modelUsed: nil, wasFallback: false))
    }

    private func fetchAll(_ queue: DatabaseQueue) throws -> [Recording] {
        try queue.read { db in try Recording.fetchAll(db) }
    }

    // MARK: - Expected schema

    /// PRAGMA table_info: cid, name, type, notnull, default, pk.
    static let expectedColumns = [
        "0|id|TEXT|0||1",
        "1|timestamp|DATETIME|1||0",
        "2|fileName|TEXT|1||0",
        "3|transcription|TEXT|1||0",
        "4|duration|DOUBLE|1||0",
        "5|status|TEXT|1|'completed'|0",
        "6|progress|DOUBLE|1|1.0|0",
        "7|sourceFileURL|TEXT|0||0",
        "8|sourceAppName|TEXT|0||0",
        "9|sourceWindowTitle|TEXT|0||0",
        "10|sourceURL|TEXT|0||0",
        "11|modelUsed|TEXT|0||0",
        "12|wasFallback|BOOLEAN|1|0|0",
    ]

    /// Index name, uniqueness, and indexed columns with their collation.
    static let expectedIndexes = [
        "recordings_on_timestamp|0|timestamp:BINARY",
        "recordings_on_transcription|0|transcription:NOCASE",
        "sqlite_autoindex_recordings_1|1|id:BINARY",
    ]

    /// SQLite keeps the CREATE statement and appends each ALTER's column to it, so a fresh
    /// database and an upgraded one only match if the migrations ran in this order.
    static let expectedTableSQL = """
        CREATE TABLE "recordings" ("id" TEXT PRIMARY KEY, "timestamp" DATETIME NOT NULL, \
        "fileName" TEXT NOT NULL, "transcription" TEXT NOT NULL COLLATE NOCASE, \
        "duration" DOUBLE NOT NULL, "status" TEXT NOT NULL DEFAULT 'completed', \
        "progress" DOUBLE NOT NULL DEFAULT 1.0, "sourceFileURL" TEXT, "sourceAppName" TEXT, \
        "sourceWindowTitle" TEXT, "sourceURL" TEXT, "modelUsed" TEXT, \
        "wasFallback" BOOLEAN NOT NULL DEFAULT 0)
        """

    // MARK: - Helpers

    private static func columns(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)").map { row in
                let dflt = (row["dflt_value"] as String?) ?? ""
                return "\(row["cid"] as Int)|\(row["name"] as String)|\(row["type"] as String)|"
                    + "\(row["notnull"] as Int)|\(dflt)|\(row["pk"] as Int)"
            }
        }
    }

    private static func indexes(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            let list = try Row.fetchAll(db, sql: "PRAGMA index_list(recordings)")
            return try list.map { index -> String in
                let name: String = index["name"]
                let columns = try Row.fetchAll(db, sql: "PRAGMA index_xinfo(\(name.quotedDatabaseIdentifier))")
                    .filter { ($0["key"] as Int) == 1 }
                    .map { "\($0["name"] as String):\($0["coll"] as String)" }
                return "\(name)|\(index["unique"] as Int)|\(columns.joined(separator: ","))"
            }.sorted()
        }
    }

    private static func tableSQL(_ queue: DatabaseQueue) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'recordings'")
        }
    }

    /// Read from GRDB's own table rather than through the migrator, so it is what the file says.
    private static func appliedMigrations(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// Schema and every row of every table, as text, for before/after comparisons.
    private static func dump(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            let schema = try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master ORDER BY name")
                .map { "\($0["type"] as String) \($0["name"] as String): \(($0["sql"] as String?) ?? "")" }
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
                """)
            let rows = try tables.flatMap { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier) ORDER BY 1")
                    .map { "\(table): \($0.description)" }
            }
            return schema + rows
        }
    }

    private static func assertSameColumns(_ actual: Recording, _ expected: Recording,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let label = expected.fileName
        XCTAssertEqual(actual.id, expected.id, label, file: file, line: line)
        XCTAssertEqual(actual.timestamp, expected.timestamp, label, file: file, line: line)
        XCTAssertEqual(actual.fileName, expected.fileName, label, file: file, line: line)
        XCTAssertEqual(actual.transcription, expected.transcription, label, file: file, line: line)
        XCTAssertEqual(actual.duration, expected.duration, label, file: file, line: line)
        XCTAssertEqual(actual.status, expected.status, label, file: file, line: line)
        XCTAssertEqual(actual.progress, expected.progress, label, file: file, line: line)
        XCTAssertEqual(actual.sourceFileURL, expected.sourceFileURL, label, file: file, line: line)
        XCTAssertEqual(actual.sourceAppName, expected.sourceAppName, label, file: file, line: line)
        XCTAssertEqual(actual.sourceWindowTitle, expected.sourceWindowTitle, label, file: file, line: line)
        XCTAssertEqual(actual.sourceURL, expected.sourceURL, label, file: file, line: line)
        XCTAssertEqual(actual.modelUsed, expected.modelUsed, label, file: file, line: line)
        XCTAssertEqual(actual.wasFallback, expected.wasFallback, label, file: file, line: line)
        XCTAssertEqual(actual.isRegeneration, expected.isRegeneration, label, file: file, line: line)
    }
}
