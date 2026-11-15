import XCTest

@testable import OpenSuperWhisper

/// Ducking lowers the output to a share of the volume it starts from, never above it.
final class DuckVolumeTests: XCTestCase {

    func testDuckingKeepsTheShareOfTheCurrentVolume() {
        XCTAssertEqual(SystemVolumeController.duckedVolume(current: 0.31, fraction: 0.3), 0.093, accuracy: 0.0001)
    }

    func testDuckingNeverRaisesAQuietOutput() {
        XCTAssertLessThan(SystemVolumeController.duckedVolume(current: 0.25, fraction: 0.5), 0.25)
    }

    func testFractionOutsideZeroToOneIsClamped() {
        XCTAssertEqual(SystemVolumeController.duckedVolume(current: 0.4, fraction: 1.5), 0.4)
        XCTAssertEqual(SystemVolumeController.duckedVolume(current: 0.4, fraction: -1), 0)
    }
}
