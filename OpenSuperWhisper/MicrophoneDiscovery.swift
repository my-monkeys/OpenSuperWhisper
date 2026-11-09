import CoreAudio
import Foundation

/// Lists input devices straight from CoreAudio. `AVCaptureDevice.DiscoverySession` was the
/// previous source and has been seen blocking the main thread at launch (macOS 26.5.1), so the
/// window never appeared; the HAL answers the same question without going through the capture
/// stack.
enum MicrophoneDiscovery {
    static func inputDevices() -> [MicrophoneService.AudioDevice] {
        allDeviceIDs().compactMap(inputDevice)
    }

    static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        scalar(UInt32.self, of: deviceID, selector: kAudioDevicePropertyTransportType)
    }

    static func isBuiltIn(transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    static func isBluetooth(transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func inputDevice(_ deviceID: AudioDeviceID) -> MicrophoneService.AudioDevice? {
        guard hasInputStreams(deviceID),
              let uid = string(of: deviceID, selector: kAudioDevicePropertyDeviceUID),
              !uid.contains("CADefaultDeviceAggregate")
        else { return nil }
        return MicrophoneService.AudioDevice(
            id: uid,
            name: string(of: deviceID, selector: kAudioObjectPropertyName) ?? uid,
            manufacturer: string(of: deviceID, selector: kAudioObjectPropertyManufacturer),
            isBuiltIn: isBuiltIn(transportType: transportType(of: deviceID))
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func scalar<T: FixedWidthInteger>(
        _ type: T.Type, of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> T? {
        var address = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
