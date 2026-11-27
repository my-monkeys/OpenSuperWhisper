import Foundation
import CoreML

/// Where the CTC audio encoder is compiled for, from the fastest to not at all.
///
/// Compiling it for the Neural Engine segfaults inside CoreML on some machines
/// (`makeProgramWithMemoryLayout`, seen on an M4 Max under macOS 27.2.1, not on an M5 Pro under
/// 27.3). A segfault cannot be caught, so the only defence is not to try the same thing again.
enum CtcComputeLevel: String, Codable, Equatable {
    case neuralEngine
    case gpu
    case cpu
    /// Every rung crashed on this OS build: boosting is skipped, dictation goes on without it.
    case unavailable

    var computeUnits: MLComputeUnits? {
        switch self {
        case .neuralEngine: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        case .cpu: .cpuOnly
        case .unavailable: nil
        }
    }

    /// The rung tried after a load at this one took the process down.
    var lower: CtcComputeLevel {
        switch self {
        case .neuralEngine: .gpu
        case .gpu: .cpu
        case .cpu, .unavailable: .unavailable
        }
    }
}

/// What survives a crash of the encoder load: the level settled on for one OS build, and the
/// load that was under way when the process last wrote it.
///
/// Kept per OS build because the crash lives in the system's compiler: a macOS update may fix
/// it, so a new build starts again at the Neural Engine.
struct CtcLoadGuardState: Codable, Equatable {
    /// The OS build `level` was settled on (`ProcessInfo.operatingSystemVersionString`, which
    /// carries the build number).
    var osBuild: String
    var level: CtcComputeLevel
    /// The level of the load in flight on `osBuild`: written before the encoder compiles,
    /// cleared when it returns, so finding it set means that load never returned.
    var inFlight: CtcComputeLevel?

    /// The state to write before a load on `osBuild`. A state from another OS build is dropped,
    /// so its level and any load it left in flight say nothing about this one.
    static func beforeLoad(_ stored: CtcLoadGuardState?, osBuild: String) -> CtcLoadGuardState {
        var state = stored.flatMap { $0.osBuild == osBuild ? $0 : nil }
            ?? CtcLoadGuardState(osBuild: osBuild, level: .neuralEngine)
        if let crashed = state.inFlight {
            state.level = crashed.lower
        }
        state.inFlight = state.level == .unavailable ? nil : state.level
        return state
    }

    /// The state once the load returned, with models or with an error: either way it did not
    /// crash, so the level stays. A load that throws keeps today's behaviour for that dictation.
    func afterLoad() -> CtcLoadGuardState {
        var state = self
        state.inFlight = nil
        return state
    }

    /// The level a stored state stepped down from, when `beforeLoad` found a crashed load on
    /// `osBuild`: nil when nothing crashed.
    static func crashedLevel(in stored: CtcLoadGuardState?, osBuild: String) -> CtcComputeLevel? {
        guard let stored, stored.osBuild == osBuild else { return nil }
        return stored.inFlight
    }
}

/// The guard's JSON file. Not a preference: it is the app's own bookkeeping, and staying out of
/// UserDefaults keeps it out of the settings archive and the prefs key contract.
enum CtcLoadGuardFile {
    static let fileName = "ctc-load-guard.json"

    /// The stored state, or nil when there is none or it cannot be read, which starts afresh at
    /// the Neural Engine.
    static func read(_ url: URL) -> CtcLoadGuardState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CtcLoadGuardState.self, from: data)
    }

    /// Written whole before the encoder compiles. A segfault loses nothing the process already
    /// handed the kernel, so no fsync: only a kernel panic mid-load would lose the record.
    static func write(_ state: CtcLoadGuardState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
