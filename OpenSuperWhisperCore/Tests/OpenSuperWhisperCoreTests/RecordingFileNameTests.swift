import XCTest
@testable import OpenSuperWhisperCore

final class RecordingFileNameTests: XCTestCase {

    private let second = Date(timeIntervalSince1970: 1_760_000_000)

    func testTwoRecordingsInTheSameSecondGetDifferentNames() {
        let first = Recording.fileName(startedAt: second, id: UUID())
        let other = Recording.fileName(startedAt: second, id: UUID())

        XCTAssertNotEqual(first, other, "one file would overwrite the other")
    }

    func testTheNameCarriesTheSecondAndTheStartOfTheId() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!

        XCTAssertEqual(Recording.fileName(startedAt: second, id: id), "1760000000-ABCDEF12.wav")
    }
}
