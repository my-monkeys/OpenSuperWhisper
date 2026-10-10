import XCTest
@testable import OpenSuperWhisperCore

/// The test target reaches the core through the host app and never links it: a second static
/// copy in the test bundle would duplicate every singleton of the core.
final class CorePackageLinkTests: XCTestCase {

    func testCoreSeesTheNativeHeaders() {
        XCTAssertEqual(whisperSampleRate, 16_000)
    }

    func testCoreIsLinkedOnceInTheHostApp() {
        XCTAssertEqual(Bundle(for: CoreBundleMarker.self), Bundle.main)
    }
}
