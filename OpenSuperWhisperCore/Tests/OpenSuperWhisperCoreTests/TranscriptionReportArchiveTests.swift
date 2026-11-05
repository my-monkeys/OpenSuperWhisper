import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// The zip exported from the reports (#168): its name, its JSON, and what is inside it.
@MainActor
final class TranscriptionReportArchiveTests: CoreTestCase {

    private var scratch: URL!
    private let exportedAt = Date(timeIntervalSince1970: 1_760_486_400) // 2025-10-15 00:00 UTC
    private let exportedWith = "OpenSuperWhisper 0.14.2 (65) · macOS 26.2 · Apple Silicon"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionReportArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: TranscriptionReport.reportsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: TranscriptionReport.reportsDirectory)
    }

    private func report(withAudio audio: String?) throws -> TranscriptionReport {
        var report = TranscriptionReportTests.report(for: TranscriptionReportTests.recording())
        if let audio {
            report.audioFileName = "\(report.id.uuidString).wav"
            try Data(audio.utf8).write(to: try XCTUnwrap(report.audioURL))
        }
        return report
    }

    func testSuggestedNameIsTheExportDay() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TranscriptionReportArchive.suggestedName(exportedAt: exportedAt, timeZone: utc),
                       "OpenSuperWhisper-reports-2025-10-15")
    }

    /// Every entry has every key, nulls included, so a script reading them needs no guessing.
    func testJSONEntriesHaveEveryKey() throws {
        let report = try report(withAudio: nil)
        let data = try TranscriptionReportArchive.json(for: [report], audioPaths: [:],
                                                       exportedAt: exportedAt, exportedWith: exportedWith)

        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["formatVersion"] as? Int, 1)
        XCTAssertEqual(document["exportedAt"] as? String, "2025-10-15T00:00:00Z")
        XCTAssertEqual(document["exportedWith"] as? String, exportedWith)
        let entries = try XCTUnwrap(document["reports"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(Set(entry.keys), [
            "id", "createdAt", "recordedAt", "problem", "comment", "writtenAs", "shouldBe", "rawText",
            "finalText", "model", "usedLocalFallback", "durationSeconds", "timing", "languageSetting",
            "appDetails", "audioFile",
        ])
        XCTAssertEqual(entry["problem"] as? String, "wrongWord")
        XCTAssertEqual(entry["rawText"] as? String, "um so the cube cuttle cluster")
        XCTAssertEqual(entry["finalText"] as? String, "So the Kubernetes cluster.")
        XCTAssertEqual(entry["model"] as? String, "Parakeet v3")
        XCTAssertEqual(entry["usedLocalFallback"] as? Bool, true)
        XCTAssertTrue(entry["audioFile"] is NSNull)
        // A report that measured nothing still has the key, as null, like every other optional.
        XCTAssertTrue(entry["timing"] is NSNull)
    }

    /// The measurement travels with the report: the zip is what the user attaches to an issue.
    func testTheEntryCarriesTheTimingBlob() throws {
        var recording = TranscriptionReportTests.recording()
        var timing = DictationTiming()
        timing.finalizeMs = 100
        timing.totalMs = 4300
        recording.timingJSON = timing.encoded
        let report = TranscriptionReportTests.report(for: recording)

        let data = try TranscriptionReportArchive.json(for: [report], audioPaths: [:],
                                                       exportedAt: exportedAt, exportedWith: exportedWith)
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["reports"] as? [[String: Any]])
        let timingObject = try XCTUnwrap(entries.first?["timing"] as? [String: Any])
        XCTAssertEqual(timingObject["version"] as? Int, 1)
        XCTAssertEqual(timingObject["finalizeMs"] as? Int, 100)
        XCTAssertEqual(timingObject["totalMs"] as? Int, 4300)
        // A stage that did not run stays absent from the JSON, not zero.
        XCTAssertNil(timingObject["cleanupMs"])
    }

    #if os(macOS)
    /// The zip holds one folder with the JSON and the audio copies, the bytes unchanged, and a
    /// report whose copy has gone missing is listed without one.
    func testZipHoldsTheJSONAndTheAudio() throws {
        let withAudio = try report(withAudio: "RIFF one")
        var lostAudio = try report(withAudio: nil)
        lostAudio.audioFileName = "gone.wav"
        let destination = scratch.appendingPathComponent("export.zip")
        try Data("an older export".utf8).write(to: destination)

        try TranscriptionReportArchive.write([withAudio, lostAudio], to: destination,
                                             exportedAt: exportedAt, exportedWith: exportedWith)

        let folder = TranscriptionReportArchive.suggestedName(exportedAt: exportedAt)
        let entries = try run("/usr/bin/unzip", "-Z1", destination.path)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }.sorted()
        XCTAssertEqual(entries, ["\(folder)/audio/\(withAudio.id.uuidString).wav", "\(folder)/reports.json"])

        let extracted = scratch.appendingPathComponent("extracted")
        _ = try run("/usr/bin/ditto", "-x", "-k", destination.path, extracted.path)
        let root = extracted.appendingPathComponent(folder)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("audio/\(withAudio.id.uuidString).wav")),
                       Data("RIFF one".utf8))
        let json = try Data(contentsOf: root.appendingPathComponent("reports.json"))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let reports = try XCTUnwrap(document["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.map { $0["id"] as? String }, [withAudio.id.uuidString, lostAudio.id.uuidString])
        XCTAssertEqual(reports[0]["audioFile"] as? String, "audio/\(withAudio.id.uuidString).wav")
        XCTAssertTrue(reports[1]["audioFile"] is NSNull)
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
        return String(decoding: output, as: UTF8.self)
    }
    #endif
}
