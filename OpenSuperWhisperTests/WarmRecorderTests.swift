import XCTest
@testable import OpenSuperWhisper

/// Whether a prepared recorder is kept between takes. It holds the system input open, and a
/// Bluetooth headset held that way stays in its call profile until the app lets go (#247).
final class WarmRecorderTests: XCTestCase {

    func testWiredOrBuiltInInputStaysWarm() {
        XCTAssertTrue(AudioRecorder.keepsWarmRecorder(activeMicIsBluetooth: false, systemInputIsBluetooth: false))
    }

    func testBluetoothMicIsNotKeptWarm() {
        XCTAssertFalse(AudioRecorder.keepsWarmRecorder(activeMicIsBluetooth: true, systemInputIsBluetooth: true))
    }

    /// Earbuds connecting while the built-in mic is chosen become the system input, and the warm
    /// recorder sits on the system input, not on the chosen mic.
    func testBluetoothSystemInputIsNotKeptWarmEvenWithTheBuiltInMicChosen() {
        XCTAssertFalse(AudioRecorder.keepsWarmRecorder(activeMicIsBluetooth: false, systemInputIsBluetooth: true))
    }
}
