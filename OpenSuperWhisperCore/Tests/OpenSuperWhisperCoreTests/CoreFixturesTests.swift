import XCTest
@testable import OpenSuperWhisperCore

/// The repository files the core tests read are where `Fixtures` looks. On the iOS Simulator this
/// also shows that the test process reads the host's paths.
final class CoreFixturesTests: CoreTestCase {

    func testFixturesAreReachable() {
        for url in [Fixtures.jfkWav, Fixtures.tinyEnModel, Fixtures.sileroVAD] {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path), url.path)
        }
    }
}
