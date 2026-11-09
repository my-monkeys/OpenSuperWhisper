//
//  HistoryPagingTests.swift
//  OpenSuperWhisperTests
//
//  A failed page fetch must not leave the history list believing a load is still running, which
//  stalled paging until the next fresh load.
//

import GRDB
import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

@MainActor
final class HistoryPagingTests: XCTestCase {

    func testAFailedFetchReleasesTheLoadingFlag() async throws {
        let database = try DatabaseQueue()
        let store = try RecordingStore(databaseQueue: database)
        try await database.write { try $0.execute(sql: "DROP TABLE recordings") }
        let model = ContentViewModel()
        model.recordingStore = store

        model.loadInitialData()
        XCTAssertTrue(model.isLoadingMore, "the load has started")
        for _ in 0..<300 where model.isLoadingMore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(model.isLoadingMore, "paging must not stall on a failed fetch")
        XCTAssertTrue(model.canLoadMore, "and the next scroll may try again")
    }
}
