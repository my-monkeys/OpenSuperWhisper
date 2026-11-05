import Foundation
import OpenSuperWhisperCore

extension MachineState {
    /// The Mac at the stop instant (#262: "the Mac's load at that moment"). Three reads at an
    /// instant the caller already holds, so it costs nothing measurable.
    ///
    /// App target only: `getloadavg` has no place in the core module's iOS build, and the core
    /// type carries the result as plain values.
    @MainActor
    static func captureNow() -> MachineState {
        var averages = [Double](repeating: 0, count: 3)
        let loaded = getloadavg(&averages, 3) == 3
        return MachineState(
            thermalState: thermalLabel(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            loadAverage1m: loaded ? averages[0] : nil)
    }

    /// The four documented states, by name. A state this build does not know must not be
    /// reported as `nominal`.
    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
