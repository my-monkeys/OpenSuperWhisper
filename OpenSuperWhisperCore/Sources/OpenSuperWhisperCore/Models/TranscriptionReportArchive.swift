import Foundation

/// The zip a user exports from their reports (#168): one `reports.json` and the audio copies
/// under `audio/`, inside a folder named after the export date. Made to be attached to an issue
/// or fed to the model benchmarks, so the JSON is stable, sorted and documented by its keys.
///
/// Writing it is the only thing this does. Nothing here sends anything anywhere.
public enum TranscriptionReportArchive {
    public static let jsonFileName = "reports.json"
    public static let audioFolderName = "audio"
    /// Bumped when a key changes meaning, so a benchmark script can refuse what it does not know.
    public static let formatVersion = 1

    /// "OpenSuperWhisper-reports-2026-10-15": the zip's file name and its top folder.
    public static func suggestedName(exportedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "OpenSuperWhisper-reports-\(formatter.string(from: exportedAt))"
    }

    /// The JSON document. `audioPaths` maps a report to its file inside the archive; a report
    /// without one gets `"audioFile": null`.
    public static func json(for reports: [TranscriptionReport], audioPaths: [UUID: String],
                            exportedAt: Date, exportedWith: String) throws -> Data {
        let document = Document(formatVersion: formatVersion, exportedAt: exportedAt, exportedWith: exportedWith,
                                reports: reports.map { Entry(report: $0, audioFile: audioPaths[$0.id]) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// Writes the zip to `destination`, replacing a file already there (the save panel asked).
    /// The reports' audio is copied as found; a copy that has gone missing is left out and its
    /// entry says so with a null `audioFile`.
    public static func write(_ reports: [TranscriptionReport], to destination: URL,
                             exportedAt: Date = Date(), exportedWith: String) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("osw-report-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(suggestedName(exportedAt: exportedAt), isDirectory: true)
        let audioFolder = folder.appendingPathComponent(audioFolderName, isDirectory: true)
        try fileManager.createDirectory(at: audioFolder, withIntermediateDirectories: true)

        var audioPaths: [UUID: String] = [:]
        for report in reports {
            guard let source = report.audioURL, fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: audioFolder.appendingPathComponent(source.lastPathComponent))
            audioPaths[report.id] = "\(audioFolderName)/\(source.lastPathComponent)"
        }
        try json(for: reports, audioPaths: audioPaths, exportedAt: exportedAt, exportedWith: exportedWith)
            .write(to: folder.appendingPathComponent(jsonFileName))

        try zip(folder, to: destination)
    }

    /// Foundation's own zipper: a coordinated read "for uploading" hands back a zip of the
    /// folder, removed once the block returns. No `Process`, no third-party archiver.
    private static func zip(_ folder: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading,
                                       error: &coordinationError) { zipped in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    // MARK: - Document

    private struct Document: Encodable {
        let formatVersion: Int
        let exportedAt: Date
        let exportedWith: String
        let reports: [Entry]
    }

    /// One report as exported. Optionals are written as null rather than left out, so every
    /// entry has the same keys.
    private struct Entry: Encodable {
        let report: TranscriptionReport
        let audioFile: String?

        enum CodingKeys: String, CodingKey {
            case id, createdAt, recordedAt, problem, comment, writtenAs, shouldBe, rawText, finalText
            case model, usedLocalFallback, durationSeconds, languageSetting, appDetails, audioFile, timing
            case ending
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(report.id, forKey: .id)
            try container.encode(report.createdAt, forKey: .createdAt)
            try container.encode(report.recordedAt, forKey: .recordedAt)
            try container.encode(report.problem.rawValue, forKey: .problem)
            try container.encode(report.comment, forKey: .comment)
            try container.encode(report.writtenAs, forKey: .writtenAs)
            try container.encode(report.shouldBe, forKey: .shouldBe)
            try container.encode(report.rawText, forKey: .rawText)
            try container.encode(report.finalText, forKey: .finalText)
            try container.encode(report.modelUsed, forKey: .model)
            try container.encode(report.wasFallback, forKey: .usedLocalFallback)
            try container.encode(report.duration, forKey: .durationSeconds)
            try container.encode(report.timing, forKey: .timing)
            try container.encode(report.ending, forKey: .ending)
            try container.encode(report.languageSetting, forKey: .languageSetting)
            try container.encode(report.appDetails, forKey: .appDetails)
            try container.encode(audioFile, forKey: .audioFile)
        }
    }
}
