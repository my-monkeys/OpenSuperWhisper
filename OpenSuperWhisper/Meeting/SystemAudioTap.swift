import AVFoundation
import CoreAudio

/// The call's side of a meeting: everything the Mac plays, captured through a Core Audio process
/// tap (#159). A tap only needs the system audio permission, not screen recording, and no bot
/// joins the call. Our own sounds (the chimes) are left out.
@available(macOS 14.4, *)
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status):
                return String(localized: "Couldn't capture the system audio (\(step), \(status)).")
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "osw.meeting.system-audio", qos: .userInitiated)

    func start(writingTo writer: MeetingTrackWriter) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("process tap", AudioHardwareCreateProcessTap(description, &tapID))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenSuperWhisper meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var streamDescription = try Self.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw TapError.failed("format", kAudioHardwareUnsupportedOperationError)
        }
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.write(buffer)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw TapError.failed(step, status)
        }
    }

    private static func ownProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.failed("output device", status) }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw TapError.failed("output device", status) }
        return uid as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.failed("format", status) }
        return format
    }
}
