import CoreAudio
import Foundation

/// Coalesces a burst of calls into one, `delay` after the last. The clock is injected so tests
/// don't have to wait.
final class Debouncer {
    typealias Cancel = () -> Void
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancel

    static let mainQueue: Scheduler = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item.cancel
    }

    private let delay: TimeInterval
    private let schedule: Scheduler
    private let action: () -> Void
    private var cancelPending: Cancel?

    init(delay: TimeInterval, schedule: @escaping Scheduler = Debouncer.mainQueue,
         action: @escaping () -> Void) {
        self.delay = delay
        self.schedule = schedule
        self.action = action
    }

    func fire() {
        cancelPending?()
        cancelPending = schedule(delay) { [weak self] in
            self?.cancelPending = nil
            self?.action()
        }
    }
}

/// Watches CoreAudio for the input device list and the system default input changing, and
/// reports on the main queue. Removes its listeners when released.
final class MicrophoneDeviceMonitor {
    /// A plug or wake produces several notifications in a row and the list is half built
    /// meanwhile; refreshing once it settles avoids showing, and resolving against, that state.
    static let devicesChangeDebounce: TimeInterval = 0.4

    private let devicesListener: Listener
    private let defaultInputListener: Listener

    init(onDevicesChanged: @escaping () -> Void, onDefaultInputChanged: @escaping () -> Void) {
        let debouncer = Debouncer(delay: Self.devicesChangeDebounce, action: onDevicesChanged)
        devicesListener = Listener(selector: kAudioHardwarePropertyDevices) { debouncer.fire() }
        defaultInputListener = Listener(
            selector: kAudioHardwarePropertyDefaultInputDevice, onChange: onDefaultInputChanged)
    }

    private final class Listener {
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        init(selector: AudioObjectPropertySelector, onChange: @escaping () -> Void) {
            address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            block = { _, _ in onChange() }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}
