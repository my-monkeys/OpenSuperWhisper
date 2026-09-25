import XCTest

@testable import OpenSuperWhisper

/// The pinned microphone while it is unplugged.
///
/// Recording already fell back to the default input and came back to the pinned device on
/// reconnection, but the Settings picker matched its selection against the connected devices
/// only, so with the pinned one unplugged it showed nothing at all: no name, no hint that
/// another input was in use.
@MainActor
final class MicrophoneDisconnectedSelectionTests: XCTestCase {

    private let builtIn = MicrophoneService.AudioDevice(
        id: "test-builtin", name: "MacBook Pro Microphone", manufacturer: "Apple", isBuiltIn: true)
    private let usb = MicrophoneService.AudioDevice(
        id: "test-usb", name: "USBAudio1.0", manufacturer: "Jieli Technology", isBuiltIn: false)

    private var savedAvailable: [MicrophoneService.AudioDevice] = []
    private var savedSelected: MicrophoneService.AudioDevice?

    override func setUp() async throws {
        savedAvailable = MicrophoneService.shared.availableMicrophones
        savedSelected = MicrophoneService.shared.selectedMicrophone
    }

    override func tearDown() async throws {
        MicrophoneService.shared.availableMicrophones = savedAvailable
        MicrophoneService.shared.selectedMicrophone = savedSelected
    }

    func testAPinnedDeviceThatIsUnpluggedIsReported() {
        let service = MicrophoneService.shared
        service.availableMicrophones = [builtIn]
        service.selectedMicrophone = usb
        XCTAssertEqual(service.disconnectedSelection, usb)
    }

    func testAPinnedDeviceThatIsPluggedInIsNot() {
        let service = MicrophoneService.shared
        service.availableMicrophones = [builtIn, usb]
        service.selectedMicrophone = usb
        XCTAssertNil(service.disconnectedSelection)
    }

    func testFollowingTheSystemInputHasNothingToReport() {
        let service = MicrophoneService.shared
        service.availableMicrophones = [builtIn]
        service.selectedMicrophone = nil
        XCTAssertNil(service.disconnectedSelection)
    }
}
