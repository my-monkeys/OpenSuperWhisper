import Foundation
import AVFoundation
import Combine

@MainActor
public class TranscriptionQueue: ObservableObject {
    public static let shared = TranscriptionQueue()

    /// Consent seam for the history-disabled prompt (lead ruling, Option A). The app
    /// wires this at launch to the NSAlert flow. FAIL-SAFE default: nil behaves as
    /// cancel/no-save — an unwired queue never proceeds without asking (consent path).
    public var confirmEnableHistory: (() -> Bool)?

    @Published public private(set) var isProcessing = false
    @Published public private(set) var currentRecordingId: UUID?
    // When the current recording began processing, for the row's elapsed-time readout.
    // Useful on long dropped files, especially with engines that don't report granular
    // progress (Apple Speech, SenseVoice) where the percentage bar can't move (#87).
    @Published public private(set) var processingStartedAt: Date?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?
    // One-off model for a specific rerun (keyed by recording id). Applied for
    // that transcription only, then the system default is restored. (F3)
    private var modelOverrides: [UUID: DictationModelOption] = [:]

    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                Task {
                    await self.recordingStore.updateRecordingStatusOnly(
                        recordingId,
                        progress: newProgress,
                        status: .transcribing
                    )
                }
            }
    }

    public func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            transcriptionService.cancelTranscription()
            currentTranscriptionTask?.cancel()
        }
    }

    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }

    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }

    public func startProcessingQueue() {
        guard !isProcessing else { return }

        isProcessing = true

        processingTask = Task {
            await cleanupMissingFiles()
            await processQueue()
            isProcessing = false
            processingTask = nil
        }
    }

    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()

        let recordingsToDelete = await Task.detached(priority: .utility) {
            var toDelete: [Recording] = []
            for recording in pendingRecordings {
                guard let sourceURLString = recording.sourceFileURL,
                      !sourceURLString.isEmpty else {
                    toDelete.append(recording)
                    continue
                }

                let sourceURL = URL(fileURLWithPath: sourceURLString)
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    toDelete.append(recording)
                }
            }
            return toDelete
        }.value
        
        for recording in recordingsToDelete {
            recordingStore.deleteRecording(recording)
        }
    }

    public func addFileToQueue(url: URL) async {
        if !AppPreferences.shared.saveTranscriptionHistory {
            // Consent gate: adding a file while history saving is off requires explicit
            // user consent via the app-wired prompt. FAIL-SAFE: nil closure = cancel.
            guard let confirm = confirmEnableHistory, confirm() else {
                return
            }
            AppPreferences.shared.saveTranscriptionHistory = true
        }

        do {
            let durationInSeconds = await (try? Task.detached(priority: .userInitiated) {
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                return CMTimeGetSeconds(duration)
            }.value) ?? 0.0

            let timestamp = Date()
            let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
            let id = UUID()

            let recording = Recording(
                id: id,
                timestamp: timestamp,
                fileName: fileName,
                transcription: "",
                duration: durationInSeconds,
                status: .pending,
                progress: 0.0,
                sourceFileURL: url.path
            )

            try await recordingStore.addRecordingSync(recording)

            startProcessingQueue()
        } catch {
            print("Failed to add file to queue: \(error)")
        }
    }

    public func requeueRecording(_ recording: Recording, model: DictationModelOption? = nil) async {
        if let model {
            modelOverrides[recording.id] = model
        }
        let sourceURL: URL? = await Task.detached(priority: .userInitiated) {
            if let existingSource = recording.sourceFileURL,
               !existingSource.isEmpty,
               FileManager.default.fileExists(atPath: existingSource) {
                return URL(fileURLWithPath: existingSource)
            } else if FileManager.default.fileExists(atPath: recording.url.path) {
                return recording.url
            }
            return nil
        }.value
        
        guard let sourceURL = sourceURL else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        do {
            try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
        } catch {
            print("Failed to update source URL: \(error)")
        }

        startProcessingQueue()
    }

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            processingStartedAt = Date()
            await processRecording(recording)
            currentRecordingId = nil
            processingStartedAt = nil
            // Enforce the retention limit after each recording finishes so the
            // count is held as a fixed-size buffer. In-progress recordings stay
            // excluded; they get pruned as soon as they finish on a later pass.
            await recordingStore.enforceRetentionPolicy()
        }
    }

    private func processRecording(_ recording: Recording) async {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let sourceURL = URL(fileURLWithPath: sourceURLString)

        let sourceExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: sourceURL.path)
        }.value
        
        guard sourceExists else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let isRegeneration = !recording.transcription.isEmpty && 
            recording.transcription != "In queue..." && 
            recording.transcription != "Starting transcription..."

        if isRegeneration {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "",
                progress: 0.0,
                status: .converting
            )
        }

        // Apply a one-off model for this rerun (from the rerun dropdown), then restore
        // the system default once it finishes — the rerun-side analog of "Just This Time".
        let restoreOverride = applyModelOverride(for: recording.id)
        defer { restoreOverride() }

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let settings = Settings()
                let text = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                    }
                }.value

                // The model that actually produced the text — the local fallback, not the
                // configured/override model, when a remote rerun fell back to local.
                let (modelUsed, wasFallback) = await MainActor.run {
                    (TranscriptionService.shared.lastUsedModel?.displayName,
                     TranscriptionService.shared.lastUsedFallback)
                }
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false,
                    modelUsed: modelUsed,
                    wasFallback: wasFallback
                )

            } catch {
                if !isRecordingCancelled(recording.id) && !Task.isCancelled {
                    await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "Failed to transcribe: \(error.localizedDescription)",
                        progress: 0.0,
                        status: .failed,
                        isRegeneration: false
                    )
                }
            }
        }

        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
    }

    /// Temporarily switch to a recording's one-off override model and return a
    /// closure restoring the previous settings + engine. No override → no-op.
    private func applyModelOverride(for recordingID: UUID) -> () -> Void {
        guard let option = modelOverrides.removeValue(forKey: recordingID) else { return {} }
        let prefs = AppPreferences.shared
        let previousEngine = prefs.selectedEngine
        let previousWhisper = prefs.selectedWhisperModelPath
        let previousFluid = prefs.fluidAudioModelVersion
        let previousRemote = prefs.remoteServerModel

        prefs.selectedEngine = option.engine
        switch option.engine {
        case "whisper": prefs.selectedWhisperModelPath = option.identifier
        case "fluidaudio": prefs.fluidAudioModelVersion = option.identifier
        case "remote": prefs.remoteServerModel = option.identifier
        default: break
        }
        transcriptionService.reloadEngine()

        return {
            prefs.selectedEngine = previousEngine
            prefs.selectedWhisperModelPath = previousWhisper
            prefs.fluidAudioModelVersion = previousFluid
            prefs.remoteServerModel = previousRemote
            self.transcriptionService.reloadEngine()
        }
    }
}
