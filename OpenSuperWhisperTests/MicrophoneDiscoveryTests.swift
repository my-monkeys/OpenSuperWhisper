import CoreAudio
import XCTest

@testable import OpenSuperWhisper

final class MicrophoneDiscoveryTests: XCTestCase {

    func testBuiltInIsDecidedByTransportTypeAlone() {
        XCTAssertTrue(MicrophoneDiscovery.isBuiltIn(transportType: kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(MicrophoneDiscovery.isBuiltIn(transportType: kAudioDeviceTransportTypeBluetooth))
        XCTAssertFalse(MicrophoneDiscovery.isBuiltIn(transportType: kAudioDeviceTransportTypeUSB))
        XCTAssertFalse(MicrophoneDiscovery.isBuiltIn(transportType: nil))
    }

    func testBluetoothCoversClassicAndLowEnergy() {
        XCTAssertTrue(MicrophoneDiscovery.isBluetooth(transportType: kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(MicrophoneDiscovery.isBluetooth(transportType: kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertFalse(MicrophoneDiscovery.isBluetooth(transportType: kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(MicrophoneDiscovery.isBluetooth(transportType: nil))
    }

    func testEnumeratedDevicesAreUniquelyIdentified() {
        let ids = MicrophoneDiscovery.inputDevices().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

final class MicrophoneSelectionTests: XCTestCase {
    private let builtIn = MicrophoneService.AudioDevice(
        id: "builtin", name: "Mac mic", manufacturer: "Apple", isBuiltIn: true)
    private let usb = MicrophoneService.AudioDevice(
        id: "usb", name: "USB mic", manufacturer: nil, isBuiltIn: false)

    func testPinnedDeviceWinsWhileConnected() {
        let result = MicrophoneSelection.usable(pinned: usb, available: [builtIn, usb], fallback: builtIn)
        XCTAssertEqual(result, usb)
    }

    func testFallbackWhilePinnedDeviceIsMissingThenPinnedAgain() {
        // The pin is an input here, never cleared: only the available list changes.
        XCTAssertEqual(MicrophoneSelection.usable(pinned: usb, available: [], fallback: nil), nil)
        XCTAssertEqual(MicrophoneSelection.usable(pinned: usb, available: [builtIn], fallback: builtIn), builtIn)
        XCTAssertEqual(MicrophoneSelection.usable(pinned: usb, available: [builtIn, usb], fallback: builtIn), usb)
    }

    func testNothingPinnedUsesTheFallback() {
        XCTAssertEqual(MicrophoneSelection.usable(pinned: nil, available: [builtIn], fallback: builtIn), builtIn)
    }

    func testAutomaticRowIsCheckedOnlyWhenNothingIsPinned() {
        XCTAssertTrue(MicrophoneSelection.isChecked(deviceID: nil, pinnedID: nil))
        XCTAssertFalse(MicrophoneSelection.isChecked(deviceID: nil, pinnedID: "usb"))
        XCTAssertFalse(MicrophoneSelection.isChecked(deviceID: "usb", pinnedID: nil))
        XCTAssertTrue(MicrophoneSelection.isChecked(deviceID: "usb", pinnedID: "usb"))
        XCTAssertFalse(MicrophoneSelection.isChecked(deviceID: "builtin", pinnedID: "usb"))
    }

    @MainActor
    func testRefreshingAnEmptyListKeepsThePinnedMicrophone() {
        let service = MicrophoneService.shared
        let saved = (service.availableMicrophones, service.selectedMicrophone)
        defer { (service.availableMicrophones, service.selectedMicrophone) = saved }
        service.selectedMicrophone = usb
        service.availableMicrophones = []
        service.refreshAvailableMicrophones()
        XCTAssertEqual(service.selectedMicrophone, usb)
    }
}

final class DebouncerTests: XCTestCase {
    private var scheduled: [(delay: TimeInterval, work: () -> Void, cancelled: Bool)] = []

    private lazy var scheduler: Debouncer.Scheduler = { [unowned self] delay, work in
        scheduled.append((delay, work, false))
        let index = scheduled.count - 1
        return { self.scheduled[index].cancelled = true }
    }

    private func runPending() {
        scheduled.filter { !$0.cancelled }.forEach { $0.work() }
        scheduled.removeAll()
    }

    func testABurstRunsTheActionOnce() {
        var runs = 0
        let debouncer = Debouncer(delay: 0.4, schedule: scheduler) { runs += 1 }
        (0..<5).forEach { _ in debouncer.fire() }
        XCTAssertEqual(scheduled.filter { !$0.cancelled }.count, 1)
        runPending()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(scheduled.first?.delay ?? 0.4, 0.4)
    }

    func testALaterBurstRunsAgain() {
        var runs = 0
        let debouncer = Debouncer(delay: 0.4, schedule: scheduler) { runs += 1 }
        debouncer.fire()
        runPending()
        debouncer.fire()
        debouncer.fire()
        runPending()
        XCTAssertEqual(runs, 2)
    }
}
