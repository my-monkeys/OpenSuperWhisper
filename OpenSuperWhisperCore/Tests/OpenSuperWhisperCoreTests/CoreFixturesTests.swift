import XCTest
@testable import OpenSuperWhisperCore

/// The repository files the core tests read are where `Fixtures` looks, and the 0.13.3 database
/// was copied into the test bundle. On the iOS Simulator this also shows that the test process
/// reads the host's paths.
final class CoreFixturesTests: CoreTestCase {

    func testFixturesAreReachable() {
        for url in [Fixtures.jfkWav, Fixtures.tinyEnModel, Fixtures.sileroVAD] {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path), url.path)
        }
        XCTAssertNotNil(Bundle.module.url(forResource: "recordings-0.13.3", withExtension: "sqlite"))
    }
}
