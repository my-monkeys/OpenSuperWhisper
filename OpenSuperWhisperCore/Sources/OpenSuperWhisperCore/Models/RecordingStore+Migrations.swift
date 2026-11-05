import GRDB

extension RecordingStore {
    /// Every schema migration, in order. Their identifiers are stored in each user's database
    /// (`grdb_migrations`), so they are never renamed or reordered.
    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1") { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
        
        migrator.registerMigration("v2_add_status") { db in
            let columns = try db.columns(in: Recording.databaseTableName)
            let columnNames = columns.map { $0.name }
            
            if !columnNames.contains("status") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "status", .text).notNull().defaults(to: "completed")
                }
            }
            if !columnNames.contains("progress") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "progress", .double).notNull().defaults(to: 1.0)
                }
            }
            if !columnNames.contains("sourceFileURL") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "sourceFileURL", .text)
                }
            }
        }

        // Appended AFTER my-monkeys' latest migration (v2_add_status). Both columns are
        // nullable text, so old rows simply get NULL. Guarded by a column-existence check
        // so re-running is a no-op.
        migrator.registerMigration("v3_add_source_context") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            for column in ["sourceAppName", "sourceWindowTitle", "sourceURL"]
            where !columnNames.contains(column) {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: column, .text)
                }
            }
        }

        migrator.registerMigration("v4_add_model_used") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !columnNames.contains("modelUsed") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "modelUsed", .text)
                }
            }
        }

        migrator.registerMigration("v5_add_was_fallback") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !columnNames.contains("wasFallback") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "wasFallback", .boolean).notNull().defaults(to: false)
                }
            }
        }

        // Nullable, so every existing row reads as "no original kept" and an older build that
        // opens the file afterwards still inserts and updates without knowing the column.
        migrator.registerMigration("v6_add_raw_transcription") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !columnNames.contains("rawTranscription") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "rawTranscription", .text)
                }
            }
        }

        migrator.registerMigration("v7_add_transcription_reports", migrate: TranscriptionReport.createTable)

        // Nullable for the same reason as v6: older rows had no style, and an older build that
        // opens the file afterwards still writes without knowing the column.
        migrator.registerMigration("v8_add_style_used") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !columnNames.contains("styleUsed") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "styleUsed", .text)
                }
            }
        }

        // Regenerating used to save a dictation's own recordings/<fileName> as its source file,
        // which made Home show it as an imported file titled with the .wav name (#274). Matched
        // on the path's tail because the storage root differs between machines.
        migrator.registerMigration("v9_clear_own_recording_source") { db in
            try db.execute(sql: """
                UPDATE recordings SET sourceFileURL = NULL
                WHERE substr(sourceFileURL, -length('/recordings/' || fileName)) = '/recordings/' || fileName
                """)
        }

        // Nullable for the same reason as v6: older rows never recorded a cleanup pass, and an older
        // build that opens the file afterwards still writes without knowing the columns.
        migrator.registerMigration("v10_add_cleanup_outcome") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            for column in ["cleanupModel", "cleanupError"] where !columnNames.contains(column) {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: column, .text)
                }
            }
        }

        // Nullable and versioned inside the value: a row written before this build has no
        // measurement, and an older build that opens the file afterwards still writes without
        // knowing the column. The report gets its own copy because a report outlives its
        // recording by design (#262).
        migrator.registerMigration("v11_add_dictation_timing") { db in
            let recordingColumns = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !recordingColumns.contains("timingJSON") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "timingJSON", .text)
                }
            }
            let reportColumns = try db.columns(in: TranscriptionReport.databaseTableName).map { $0.name }
            if !reportColumns.contains("timingJSON") {
                try db.alter(table: TranscriptionReport.databaseTableName) { t in
                    t.add(column: "timingJSON", .text)
                }
            }
        }

        return migrator
    }
}
