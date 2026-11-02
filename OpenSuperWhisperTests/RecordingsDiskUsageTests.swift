import XCTest
@testable import OpenSuperWhisper
import OpenSuperWhisperCore

@MainActor
final class RecordingsDiskUsageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("osw-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testScanSumsAllocatedSizeOfEveryFile() throws {
        let a = try file("a.wav", bytes: 100_000)
        let b = try file("b.wav", bytes: 250_000)
        let total = RecordingsDiskUsage.scan(folder)
        XCTAssertEqual(total.count, 2)
        XCTAssertEqual(total.bytes, RecordingsDiskUsage.allocatedSize(of: a)! + RecordingsDiskUsage.allocatedSize(of: b)!)
        XCTAssertGreaterThanOrEqual(total.bytes, 350_000)
    }

    func testMissingFilesWeighNothing() {
        let ghost = folder.appendingPathComponent("gone.wav")
        XCTAssertEqual(RecordingsDiskUsage.measure([ghost]), .init(bytes: 0, count: 0))
        XCTAssertEqual(RecordingsDiskUsage.scan(folder.appendingPathComponent("nope")), .init(bytes: 0, count: 0))
    }

    func testNothingIsPublishedBeforeTheFirstCount() async throws {
        let usage = RecordingsDiskUsage(directory: { self.folder })
        XCTAssertNil(usage.total)
        usage.recordingSaved(at: try file("early.wav", bytes: 10_000))
        XCTAssertNil(usage.total, "an increment before the first count would be a partial total")
        await usage.refresh()
        XCTAssertEqual(usage.total?.count, 1)
    }

    func testSavedAndRemovedRecordingsMoveTheTotal() async throws {
        let first = try file("1.wav", bytes: 100_000)
        let usage = RecordingsDiskUsage(directory: { self.folder })
        await usage.refresh()
        let base = try XCTUnwrap(usage.total)

        let second = try file("2.wav", bytes: 300_000)
        usage.recordingSaved(at: second)
        let size2 = RecordingsDiskUsage.allocatedSize(of: second)!
        XCTAssertEqual(usage.total, .init(bytes: base.bytes + size2, count: 2))

        usage.recordingsRemoved(RecordingsDiskUsage.measure([second]))
        XCTAssertEqual(usage.total, base)

        usage.recordingsRemoved(RecordingsDiskUsage.measure([first, first]))
        XCTAssertEqual(usage.total, .init(bytes: 0, count: 0), "never goes negative")
    }

    func testRefreshCorrectsADrift() async throws {
        let usage = RecordingsDiskUsage(directory: { self.folder })
        let kept = try file("kept.wav", bytes: 50_000)
        await usage.refresh()
        try FileManager.default.removeItem(at: kept)
        await usage.refresh()
        XCTAssertEqual(usage.total, .init(bytes: 0, count: 0))
    }

    func testLabelsStayEmptyUntilThereIsSomethingToWeigh() {
        XCTAssertNil(RecordingsSizeLabel.size(nil))
        XCTAssertNil(RecordingsSizeLabel.size(.init(bytes: 0, count: 0)))
        XCTAssertNil(RecordingsSizeLabel.sizeAndCount(nil))
    }

    func testLabelsFormatSizeAndCount() throws {
        let total = RecordingsDiskUsage.Total(bytes: 7_700_000_000, count: 11_664)
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(RecordingsSizeLabel.size(total, locale: english), "7.7 GB")
        let both = try XCTUnwrap(RecordingsSizeLabel.sizeAndCount(total, locale: english))
        XCTAssertTrue(both.hasPrefix("7.7 GB · "), both)
        XCTAssertTrue(both.contains("11,664") || both.contains("11664"), both)
        XCTAssertTrue(both.hasSuffix("recordings"), both)
        let french = try XCTUnwrap(RecordingsSizeLabel.size(total, locale: Locale(identifier: "fr_FR")))
        XCTAssertTrue(french.contains("7,7"), french)
        let single = try XCTUnwrap(RecordingsSizeLabel.sizeAndCount(.init(bytes: 4096, count: 1), locale: english))
        XCTAssertTrue(single.hasSuffix("1 recording"), single)
    }
}
