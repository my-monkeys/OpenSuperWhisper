import Foundation
import CoreML
import FluidAudio
import os

/// The one place the CTC models vocabulary boosting runs on are loaded, for the batch rescorer
/// (`FluidAudioEngine`) and the live caption alike.
///
/// Loaded the first time a boost is actually used: ~64 MB a user with no dictionary boost, no
/// snippet boost and no field context never pays for. Then shared for the life of the process,
/// so the encoder is compiled once rather than once per path; concurrent first callers wait on
/// the same load. The model does not depend on the ASR model version: every path asked for
/// `.ctc110m` whatever `AsrModelVersion` ran.
///
/// The encoder load is guarded (`CtcLoadGuardState`): compiling it can segfault inside CoreML,
/// so each load is recorded before it starts, and a record still there at the next load steps
/// the compute units down instead of crashing on every dictation.
public actor CtcModelLoader {
    public static let shared = CtcModelLoader(
        guardFile: AppIdentity.storageRoot()?.appendingPathComponent(CtcLoadGuardFile.fileName))

    private static let variant = CtcModelVariant.ctc110m
    /// `Diag.subsystem` in the app, so `log show` finds these lines with the rest.
    private static let log = Logger(subsystem: "fr.my-monkey.opensuperwhisper", category: "ctc")

    private let guardFile: URL?
    private var load: Task<CtcModels?, Error>?

    init(guardFile: URL?) {
        self.guardFile = guardFile
    }

    /// The loaded models, or nil when the encoder crashed at every level on this OS build: the
    /// caller then transcribes without boosting, as with no terms. A load that throws is not
    /// kept, so the next dictation tries again.
    public func models() async throws -> CtcModels? {
        let task = load ?? Task { try await Self.loadModels(guardFile: guardFile) }
        load = task
        do {
            return try await task.value
        } catch {
            if load == task { load = nil }
            throw error
        }
    }

    private static func loadModels(guardFile: URL?) async throws -> CtcModels? {
        let osBuild = ProcessInfo.processInfo.operatingSystemVersionString
        let stored = guardFile.flatMap(CtcLoadGuardFile.read)
        let state = CtcLoadGuardState.beforeLoad(stored, osBuild: osBuild)
        logDecision(state, crashed: CtcLoadGuardState.crashedLevel(in: stored, osBuild: osBuild))
        guard let computeUnits = state.level.computeUnits else {
            record(state, in: guardFile)
            return nil
        }

        let directory = CtcModels.defaultCacheDirectory(for: variant)
        // The front end first, CPU only like FluidAudio loads it. It also downloads whatever the
        // cache lacks, so the window the guard records below is the encoder compile alone: a
        // quit during a first download is not taken for a crash.
        let melSpectrogram = try await loadModel(ModelNames.CTC.melSpectrogramPath, in: directory,
                                                 computeUnits: CtcModels.melSpectrogramConfiguration().computeUnits)
        record(state, in: guardFile)
        defer { record(state.afterLoad(), in: guardFile) }
        let encoder = try await loadModel(ModelNames.CTC.audioEncoderPath, in: directory,
                                          computeUnits: computeUnits)
        return CtcModels(
            melSpectrogram: melSpectrogram,
            encoder: encoder,
            configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: computeUnits),
            vocabulary: try vocabulary(in: directory),
            variant: variant,
            directory: directory)
    }

    /// One model of the CTC repo, the way `CtcModels.load` loads it: ModelHub takes the folder
    /// above the repo's own.
    private static func loadModel(_ name: String, in directory: URL,
                                  computeUnits: MLComputeUnits) async throws -> MLModel {
        let models = try await ModelHub.loadModels(variant.repo, modelNames: [name],
                                                   directory: directory.deletingLastPathComponent(),
                                                   computeUnits: computeUnits)
        guard let model = models[name] else {
            throw AsrModelsError.loadingFailed("Failed to load CTC \(name)")
        }
        return model
    }

    /// The token table, read as `CtcModels` reads it (its loader is private at the pin):
    /// `vocab.json` maps each id, as a string, to its token.
    private static func vocabulary(in directory: URL) throws -> [Int: String] {
        let url = directory.appendingPathComponent(ModelNames.CTC.vocabularyPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AsrModelsError.modelNotFound(ModelNames.CTC.vocabularyPath, url)
        }
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: table.compactMap { key, token in
            Int(key).map { ($0, token) }
        })
    }

    /// Without a file nothing can be guarded, but the load itself still goes ahead: failing to
    /// write bookkeeping is no reason to drop the boost.
    private static func record(_ state: CtcLoadGuardState, in file: URL?) {
        guard let file else { return }
        do {
            try CtcLoadGuardFile.write(state, to: file)
        } catch {
            log.error("CTC load guard not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func logDecision(_ state: CtcLoadGuardState, crashed: CtcComputeLevel?) {
        if let crashed {
            log.error("""
                CTC encoder load crashed at \(crashed.rawValue, privacy: .public) on \
                \(state.osBuild, privacy: .public), stepping down to \(state.level.rawValue, privacy: .public)
                """)
        } else if state.level == .unavailable {
            log.notice("CTC boosting unavailable on \(state.osBuild, privacy: .public): every level crashed")
        }
    }
}
