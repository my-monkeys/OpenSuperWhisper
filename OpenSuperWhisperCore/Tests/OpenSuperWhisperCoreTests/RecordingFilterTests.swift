import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// The Home filters page through the database rather than the loaded rows: a filter applied to
/// the first hundred recordings would hide every older failure or import. These pin what each
/// filter matches, that it combines with the search, and that the count spans the whole history.
@MainActor
final class RecordingFilterTests: CoreTestCase {

    private func recording(_ seconds: TimeInterval, _ text: String, status: RecordingStatus = .completed,
                           file: String? = nil) -> Recording {
        Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: seconds), fileName: "\(Int(seconds)).wav",
                  transcription: text, duration: 1, status: status, progress: 1, sourceFileURL: file)
    }

    private func makeStore() async throws -> RecordingStore {
        let queue = try DatabaseQueue()
        let store = try RecordingStore(databaseQueue: queue)
        let rows = [
            recording(100, "Dictated hello"),
            recording(200, "Imported hello", file: "/tmp/a.m4a"),
            recording(300, "Server unreachable", status: .failed),
            recording(400, "Dropped file failed", status: .failed, file: "/tmp/b.mp3"),
            recording(500, "Another dictation"),
        ]
        try await queue.write { db in for row in rows { try row.insert(db) } }
        return store
    }

    private func texts(_ store: RecordingStore, _ filter: RecordingFilter, query: String = "",
                       limit: Int = 100, offset: Int = 0) async throws -> [String] {
        try await store.fetchRecordings(filter: filter, query: query, limit: limit, offset: offset)
            .map(\.transcription)
    }

    func testEachFilterMatchesItsKindNewestFirst() async throws {
        let store = try await makeStore()
        let all = try await texts(store, .all)
        XCTAssertEqual(all, ["Another dictation", "Dropped file failed", "Server unreachable",
                             "Imported hello", "Dictated hello"])
        let dictations = try await texts(store, .dictations)
        XCTAssertEqual(dictations, ["Another dictation", "Server unreachable", "Dictated hello"])
        let files = try await texts(store, .files)
        XCTAssertEqual(files, ["Dropped file failed", "Imported hello"])
        let errors = try await texts(store, .errors)
        XCTAssertEqual(errors, ["Dropped file failed", "Server unreachable"])
    }

    func testFilterCombinesWithTheSearchCaseInsensitively() async throws {
        let store = try await makeStore()
        let hello = try await texts(store, .all, query: "HELLO")
        XCTAssertEqual(hello, ["Imported hello", "Dictated hello"])
        let importedHello = try await texts(store, .files, query: "hello")
        XCTAssertEqual(importedHello, ["Imported hello"])
    }

    func testFilterPages() async throws {
        let store = try await makeStore()
        let second = try await texts(store, .all, limit: 2, offset: 2)
        XCTAssertEqual(second, ["Server unreachable", "Imported hello"])
    }

    func testCountSpansTheWholeHistory() async throws {
        let store = try await makeStore()
        let errors = await store.countRecordings(filter: .errors)
        XCTAssertEqual(errors, 2)
        let all = await store.countRecordings(filter: .all)
        XCTAssertEqual(all, 5)
    }
}
