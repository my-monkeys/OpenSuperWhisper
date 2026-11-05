import XCTest
@testable import OpenSuperWhisper

final class MoveToApplicationsTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone")
    private var downloads: URL { home.appendingPathComponent("Downloads") }

    private func offers(_ path: String, readOnly: Bool = false) -> Bool {
        MoveToApplications.shouldOffer(
            bundleURL: URL(fileURLWithPath: path), volumeIsReadOnly: readOnly, downloadsURL: downloads)
    }

    func testDiskImageOffers() {
        XCTAssertTrue(offers("/Volumes/OpenSuperWhisper/OpenSuperWhisper.app", readOnly: true))
    }

    func testTranslocatedOffers() {
        XCTAssertTrue(offers("/private/var/folders/ab/xyz/AppTranslocation/1234/d/OpenSuperWhisper.app"))
    }

    func testDownloadsAndSubfolderOffer() {
        XCTAssertTrue(offers("/Users/someone/Downloads/OpenSuperWhisper.app"))
        XCTAssertTrue(offers("/Users/someone/Downloads/unzipped/OpenSuperWhisper.app"))
    }

    func testStablePlacesDoNotOffer() {
        XCTAssertFalse(offers("/Applications/OpenSuperWhisper.app"))
        XCTAssertFalse(offers("/Users/someone/Applications/OpenSuperWhisper.app"))
        XCTAssertFalse(offers("/Users/someone/Apps/OpenSuperWhisper.app"))
        XCTAssertFalse(offers("/Users/someone/osw-worktrees/OSW-x/build/Build/Products/Debug/OpenSuperWhisper.app"))
    }

    func testSiblingOfDownloadsDoesNotOffer() {
        XCTAssertFalse(offers("/Users/someone/Downloads-old/OpenSuperWhisper.app"))
    }

    func testDestinationIsApplicationsWhenWritable() {
        let folder = MoveToApplications.destinationFolder(canWrite: { _ in true }, home: home)
        XCTAssertEqual(folder.path, "/Applications")
    }

    func testDestinationFallsBackToUserApplications() {
        let folder = MoveToApplications.destinationFolder(canWrite: { _ in false }, home: home)
        XCTAssertEqual(folder.path, "/Users/someone/Applications")
    }
}
