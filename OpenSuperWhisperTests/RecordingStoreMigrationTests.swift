import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Commit 0, scenario 2 (migrations): pin the RecordingStore migration chain against
/// in-memory GRDB queues via the `RecordingStore(dbQueue:)` seam — final schema,
/// registered migration identifiers, idempotent re-run, and upgrade from a legacy
/// v1-shaped database.
@MainActor
final class RecordingStoreMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue { try DatabaseQueue() }

    /// The 13 columns the v1→v5 chain must produce, in coding order.
    private let expectedColumns = [
        "id", "timestamp", "fileName", "transcription", "duration", "status", "progress",
        "sourceFileURL", "sourceAppName", "sourceWindowTitle", "sourceURL", "modelUsed", "wasFallback",
    ]

    func testFreshDatabaseMigratesToFullSchema() throws {
        let queue = try makeQueue()
        _ = try RecordingStore(dbQueue: queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists(Recording.databaseTableName))
            let columns = try db.columns(in: Recording.databaseTableName).map { $0.name }
            for column in expectedColumns {
                XCTAssertTrue(columns.contains(column), "missing migrated column: \(column)")
            }

            // The v1 DDL pinned from sqlite_master: nocase collation on transcription.
            let ddl = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?",
                                          arguments: [Recording.databaseTableName]) ?? ""
            XCTAssertTrue(ddl.contains("COLLATE NOCASE"),
                          "transcription column must keep its nocase collation, DDL was: \(ddl)")
        }
    }

    func testMigrationChainRegistersExactlyFiveIdentifiers() throws {
        let queue = try makeQueue()
        _ = try RecordingStore(dbQueue: queue)

        let identifiers = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(identifiers, [
            "v1", "v2_add_status", "v3_add_source_context", "v4_add_model_used", "v5_add_was_fallback",
        ], "the migration chain must stay exactly this set, in registration order")
    }

    func testMigrationIsIdempotentOnReopen() throws {
        let queue = try makeQueue()
        _ = try RecordingStore(dbQueue: queue)
        // Second store over the same queue: migrations re-run and must be a no-op.
        XCTAssertNoThrow(try RecordingStore(dbQueue: queue))
    }

    func testLegacyV1DatabaseUpgradesPreservingRowsAndDefaults() async throws {
        let queue = try makeQueue()

        // Replicate a legacy v1-era database: the original five columns only, one row.
        let legacyID = UUID()
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id TEXT PRIMARY KEY,
                    timestamp DATETIME NOT NULL,
                    fileName TEXT NOT NULL,
                    transcription TEXT NOT NULL,
                    duration DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO recordings (id, timestamp, fileName, transcription, duration)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [legacyID.uuidString, Date(timeIntervalSince1970: 1_700_000_000),
                                 "legacy.wav", "legacy text", 1.5])
        }

        let store = try RecordingStore(dbQueue: queue)

        let columns = try await queue.read { db in
            try db.columns(in: Recording.databaseTableName).map { $0.name }
        }
        for column in expectedColumns {
            XCTAssertTrue(columns.contains(column), "legacy upgrade missing column: \(column)")
        }

        let migrated = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(migrated.count, 1, "legacy row must survive the migration chain")
        let row = try XCTUnwrap(migrated.first)
        XCTAssertEqual(row.id, legacyID)
        XCTAssertEqual(row.transcription, "legacy text")
        // v2 defaults pinned by the migration DDL:
        XCTAssertEqual(row.status, .completed, "v2 default status must be completed")
        XCTAssertEqual(row.progress, 1.0, "v2 default progress must be 1.0")
        // v5 default:
        XCTAssertFalse(row.wasFallback, "v5 default wasFallback must be false")
    }
}
