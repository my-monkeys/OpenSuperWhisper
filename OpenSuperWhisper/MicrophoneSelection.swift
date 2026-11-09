import Foundation

/// The two decisions about the microphone choice that don't need CoreAudio, so they can be tested.
enum MicrophoneSelection {
    /// The device to record from. The pinned one while it is connected; otherwise the fallback,
    /// without the pin being forgotten: it can vanish from the list for a moment (wake from
    /// sleep, re-enumeration) and has to be back in charge when it reappears.
    static func usable(
        pinned: MicrophoneService.AudioDevice?,
        available: [MicrophoneService.AudioDevice],
        fallback: @autoclosure () -> MicrophoneService.AudioDevice?
    ) -> MicrophoneService.AudioDevice? {
        if let pinned, available.contains(where: { $0.id == pinned.id }) { return pinned }
        return fallback()
    }

    /// Whether a status bar menu row carries the check mark. `deviceID` is nil for the
    /// System Default row, which owns the mark while nothing is pinned; device rows then stay
    /// unchecked so the menu never shows two choices at once.
    static func isChecked(deviceID: String?, pinnedID: String?) -> Bool {
        deviceID == pinnedID
    }
}
