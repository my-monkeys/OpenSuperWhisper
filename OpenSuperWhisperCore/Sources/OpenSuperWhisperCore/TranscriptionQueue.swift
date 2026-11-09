import Foundation
import AVFoundation
import Combine

@MainActor
public class TranscriptionQueue: ObservableObject {
    public static let shared = TranscriptionQueue(transcriptionService: .shared, recordingStore: .shared,
                                                  makeSettings: CoreAccess.makeSettings,
                                                  confirmEnableHistory: CoreAccess.confirmEnableHistory)

    @Published public private(set) var isProcessing = false
    @Published public private(set) var currentRecordingId: UUID?
    // When the current recording began processing, for the row's elapsed-time readout.
    // Useful on long dropped files, especially with engines that don't report granular
    // progress (Apple Speech, SenseVoice) where the percentage bar can't move (#87).
    @Published public private(set) var processingStartedAt: Date?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private let makeSettings: @MainActor @Sendable () -> TranscriptionSettings
    private let confirmEnableHistory: @MainActor @Sendable () async -> Bool
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    /// Names the running file's transcription to the service, so cancelling it or reading its
    /// progress cannot touch a dictation that holds the engine instead.
    private var currentOperation: UUID?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?
    // One-off model for a specific rerun (keyed by recording id). Applied for
    // that transcription only, then the system default is restored. (F3)
    private var modelOverrides: [UUID: DictationModelOption] = [:]

    init(transcriptionService: TranscriptionService, recordingStore: RecordingStore,
         makeSettings: @escaping @MainActor @Sendable () -> TranscriptionSettings,
         confirmEnableHistory: @escaping @MainActor @Sendable () async -> Bool) {
        self.transcriptionService = transcriptionService
        self.recordingStore = recordingStore
        self.makeSettings = makeSettings
        self.confirmEnableHistory = confirmEnableHistory
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      let operation = self.currentOperation,
                      self.transcriptionService.activeOperation == operation,
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

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            if let currentOperation { transcriptionService.cancelTranscription(operation: currentOperation) }
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
            for recording in pendingRecordings where Self.existingAudioSource(of: recording) == nil {
                toDelete.append(recording)
            }
            return toDelete
        }.value
        
        for recording in recordingsToDelete {
            recordingStore.deleteRecording(recording)
        }
    }

    public func addFileToQueue(url: URL) async {
        if !CoreAccess.preferences.saveTranscriptionHistory {
            guard await confirmEnableHistory() else {
                return
            }
            CoreAccess.preferences.saveTranscriptionHistory = true
        }

        do {
            let durationInSeconds = await (try? Task.detached(priority: .userInitiated) {
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                return CMTimeGetSeconds(duration)
            }.value) ?? 0.0

            let timestamp = Date()
            let id = UUID()
            let fileName = Recording.fileName(startedAt: timestamp, id: id)

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
        let sourceURL = await Task.detached(priority: .userInitiated) {
            Self.existingAudioSource(of: recording)
        }.value

        guard sourceURL != nil else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        // A rerun starts a new engine run: the previous measurement must not survive it (#262).
        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true,
            clearTiming: true
        )

        startProcessingQueue()
    }

    /// Where a recording's audio can be read now. An import keeps its original file; a dictation
    /// has no `sourceFileURL` and is read from its own file. The rerun must not save that file as
    /// the source, or Home would show the dictation as an imported file named after its .wav.
    nonisolated static func existingAudioSource(of recording: Recording) -> URL? {
        if let source = recording.sourceFileURL, !source.isEmpty,
           FileManager.default.fileExists(atPath: source) {
            return URL(fileURLWithPath: source)
        }
        return FileManager.default.fileExists(atPath: recording.url.path) ? recording.url : nil
    }

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            let operation = UUID()
            currentOperation = operation
            processingStartedAt = Date()
            await processRecording(recording, operation: operation)
            currentRecordingId = nil
            currentOperation = nil
            processingStartedAt = nil
            // Enforce the retention limit after each recording finishes so the
            // count is held as a fixed-size buffer. In-progress recordings stay
            // excluded; they get pruned as soon as they finish on a later pass.
            await recordingStore.enforceRetentionPolicy()
        }
    }

    /// A video's sound is written straight into the recording's file; audio is read in place.
    private func audioToTranscribe(_ source: URL, for recording: Recording) async throws -> URL {
        guard VideoSoundtrack.isVideo(source) else { return source }
        let destination = recording.url
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await VideoSoundtrack.extract(from: source, to: destination)
        }.value
        return destination
    }

    private func processRecording(_ recording: Recording, operation: UUID) async {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        let sourceURL = await Task.detached(priority: .userInitiated) {
            Self.existingAudioSource(of: recording)
        }.value

        guard let sourceURL else {
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

        // Pull this rerun's one-off model (from the rerun dropdown) and hand it to
        // transcribeAudio, which swaps + restores the engine *inside* the shared engine gate.
        // The old applyModelOverride path called reloadEngine() out here, before acquiring the
        // gate — tearing the engine down under an in-flight (dictation) transcription that still
        // held it. Routing it through the parameter keeps the swap serialized with everything
        // else. `applyOneOffModel` treats nil / already-active as a no-op, so a plain rerun is
        // unchanged. (parallel-recording review)
        let overrideOption = modelOverrides.removeValue(forKey: recording.id)

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let audioURL = try await audioToTranscribe(sourceURL, for: recording)
                let settings = makeSettings()
                let text = try await transcriptionService.transcribeAudio(
                    url: audioURL, settings: settings, modelOverride: overrideOption, operation: operation)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if audioURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        try FileManager.default.copyItem(at: audioURL, to: finalURL)
                    }
                }.value

                // The model that actually produced the text — the local fallback, not the
                // configured/override model, when a remote rerun fell back to local.
                let (modelUsed, wasFallback) = await MainActor.run {
                    (self.transcriptionService.lastUsedModel?.displayName,
                     self.transcriptionService.lastUsedFallback)
                }
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false,
                    modelUsed: modelUsed,
                    wasFallback: wasFallback,
                    rawTranscription: text
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

}
