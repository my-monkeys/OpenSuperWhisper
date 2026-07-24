import Combine
import Foundation
import WhisperCore

/// Runs hotkey dictations (transcribe → save → paste) on a background, serial queue so the user is
/// never blocked from starting the next recording while a previous one is still being transcribed.
/// Items are processed strictly in recording-start order, so their pasted text lands in the same
/// order the clips were recorded — recording is decoupled from transcription, but output order is
/// preserved.
///
/// Concurrency: the pipeline drains its own queue serially, and `TranscriptionService.transcribeAudio`
/// additionally serializes against every other transcription source (file-drop queue, reruns) via a
/// shared gate — the engines share one non-thread-safe context. Because no other transcription can
/// interleave a given item's run, reading `lastUsedModel`/`lastUsedFallback` right after it is safe.
@MainActor
final class DictationPipeline: ObservableObject {
    static let shared = DictationPipeline()

    /// Frontmost-app context captured at record time, carried per dictation so the history row
    /// shows where THIS clip was dictated — not wherever focus moved to by the time it's processed.
    struct ContextSnapshot {
        var appName: String? = nil
        var windowTitle: String? = nil
        var fullURL: String? = nil
    }

    private struct PendingDictation {
        let id: UUID
        let seq: Int
        let startedAt: Date
        let tempURL: URL
        let streamedFallback: String
        let context: ContextSnapshot
        /// Model that was active when this clip was recorded. Applied for this clip's transcription
        /// even if a later recording has since switched the global model. (#model-snapshot)
        let modelOption: DictationModelOption?
    }

    /// Dictations waiting in the queue plus the one currently being processed. Drives optional
    /// UI (the indicator shows the count while recording) and diagnostics.
    @Published private(set) var pendingCount = 0
    /// True while the background loop is draining the queue.
    @Published private(set) var isProcessing = false

    /// Test seam: when set, used instead of the real engine so unit tests can exercise queue
    /// ordering / pendingCount / no-speech / failure paths without a model. nil in production.
    var transcribeOverride: ((URL, Settings) async throws -> String)?

    private var queue: [PendingDictation] = []
    private var inFlight = false
    private var seqCounter = 0
    private var loopTask: Task<Void, Never>?

    private let transcriptionService = TranscriptionService.shared
    private let recordingStore = RecordingStore.shared
    private let recorder = AudioRecorder.shared

    private init() {}

    /// Enqueue a finished recording for background transcription + paste. Returns immediately; the
    /// work drains on the serial loop. Called on the main actor from the indicator's stop handler.
    /// `seq` is monotonic and assigned here, so append order == recording-start order.
    func enqueue(tempURL: URL, startedAt: Date, streamedFallback: String,
                 context: ContextSnapshot, modelOption: DictationModelOption?) {
        seqCounter += 1
        queue.append(PendingDictation(
            id: UUID(),
            seq: seqCounter,
            startedAt: startedAt,
            tempURL: tempURL,
            streamedFallback: streamedFallback,
            context: context,
            modelOption: modelOption))
        refreshPendingCount()
        startLoopIfNeeded()
    }

    private func startLoopIfNeeded() {
        guard loopTask == nil else { return }
        isProcessing = true
        loopTask = Task { [weak self] in
            guard let self else { return }
            while let next = self.dequeue() {
                self.inFlight = true
                await self.process(next)
                self.inFlight = false
                self.refreshPendingCount()
            }
            self.isProcessing = false
            self.loopTask = nil
            self.refreshPendingCount()
        }
    }

    /// Pop the earliest-recorded pending dictation. FIFO == start order (seq is monotonic and the
    /// queue is only appended to on the main actor), so no explicit sort is needed. There is no
    /// `await` between a failing `dequeue()` and the loop clearing `loopTask`, so — on the main
    /// actor — a concurrent `enqueue` can never strand an item.
    private func dequeue() -> PendingDictation? {
        guard !queue.isEmpty else { return nil }
        let item = queue.removeFirst()
        refreshPendingCount()
        return item
    }

    private func refreshPendingCount() {
        pendingCount = queue.count + (inFlight ? 1 : 0)
    }

    private func process(_ item: PendingDictation) async {
        let settings = Settings()
        do {
            let rawText: String
            if let transcribeOverride {
                rawText = try await transcribeOverride(item.tempURL, settings)
            } else {
                rawText = try await transcriptionService.transcribeAudio(
                    url: item.tempURL, settings: settings, modelOverride: item.modelOption)
            }
            // Which model actually produced this text — snapshot it *now*, before the LLM and
            // audio-duration awaits below. transcribeAudio has returned so these are still this
            // item's values, but its engine gate is already released: during those awaits a
            // file-drop/rerun transcription could acquire the gate and overwrite
            // `lastUsedModel`/`lastUsedFallback`, mislabeling this history row. (parallel-recording review)
            let modelUsed = transcriptionService.lastUsedModel?.displayName ?? ModelCatalog.activeOption()?.displayName
            let wasFallback = transcriptionService.lastUsedFallback
            var text = AppPreferences.shared.cleanTranscription(rawText)

            // File pass found nothing. Fall back to the live preview if it caught the words (short
            // clip); only with neither is it genuinely "no speech" — then drop it (no empty
            // recording) and surface a brief notice. (#short-dictation)
            if text == TranscriptionResult.noSpeech
                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let fallback = AppPreferences.shared
                    .cleanTranscription(item.streamedFallback)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fallback.isEmpty else {
                    try? FileManager.default.removeItem(at: item.tempURL)
                    IndicatorWindowManager.shared.flash(.info("No speech detected"))
                    return
                }
                text = fallback
            }

            // Optional LLM cleanup (no-op when disabled; returns the raw text on failure).
            text = await LLMPostProcessor.process(text)

            // Trailing "press enter" voice command (opt-in): strip it and remember to press Return
            // after insertion, submitting the message/prompt.
            let (strippedText, shouldSubmit) = AppPreferences.shared.stripSubmitCommand(text)
            text = strippedText
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            var hookAudioPath: String? = nil
            if hasText && AppPreferences.shared.saveTranscriptionHistory {
                // Use the record-start time as the row timestamp (when the user actually dictated),
                // not the later processing time. The id suffix keeps two clips that finish within
                // the same second from colliding on one on-disk file.
                let timestamp = item.startedAt
                let recordingId = item.id
                let fileName = "\(Int(timestamp.timeIntervalSince1970))-\(recordingId.uuidString.prefix(8)).wav"
                let finalURL = Recording(
                    id: recordingId,
                    timestamp: timestamp,
                    fileName: fileName,
                    transcription: text,
                    duration: 0,
                    status: .completed,
                    progress: 1.0,
                    sourceFileURL: nil
                ).url

                try recorder.moveTemporaryRecording(from: item.tempURL, to: finalURL)
                hookAudioPath = finalURL.path

                await storeRecording(
                    id: recordingId, timestamp: timestamp, fileName: fileName,
                    finalURL: finalURL, transcription: text,
                    status: .completed, progress: 1.0, context: item.context,
                    modelUsed: modelUsed, wasFallback: wasFallback)
            } else {
                try? FileManager.default.removeItem(at: item.tempURL)
            }

            let pasteTargetMissing = hasText ? insertText(text) : false
            if hasText {
                PostRecordHook.runIfEnabled(text: text, audioPath: hookAudioPath, timestamp: item.startedAt, duration: 0)
            }

            // Submit only when auto-paste actually inserted text somewhere. A short settle delay lets
            // the pasted text land in the field before Return reaches it.
            if shouldSubmit && AppPreferences.shared.autoPasteTranscription && !pasteTargetMissing {
                try? await Task.sleep(nanoseconds: 120_000_000)
                TextInserter.pressReturn()
            }

            // No editable target was found — the text is on the clipboard; tell the user to paste it.
            if pasteTargetMissing {
                IndicatorWindowManager.shared.flash(.info("Copied — press ⌘V to paste"))
            }
        } catch {
            print("Dictation transcription failed: \(error)")
            // Don't lose the audio on failure. When history is on, keep the recording with a .failed
            // status + retry message so it shows in the log and can be re-run with the regenerate (↻)
            // button. Otherwise discard. Either way, surface the failure — silent loss is worse.
            if AppPreferences.shared.saveTranscriptionHistory,
               let saved = persistFailedRecording(timestamp: item.startedAt, tempURL: item.tempURL) {
                await storeRecording(
                    id: saved.id, timestamp: saved.timestamp, fileName: saved.fileName,
                    finalURL: saved.url, transcription: "Transcription failed — click ↻ to try again.",
                    status: .failed, progress: 0, context: item.context,
                    modelUsed: nil, wasFallback: false)
            } else {
                try? FileManager.default.removeItem(at: item.tempURL)
            }
            IndicatorWindowManager.shared.flash(.error("Transcription failed"))
        }
    }

    /// Insert a recording (already at its final URL) into the store with the measured audio duration
    /// and the captured source context (app / window / URL / model used). Moved here from the
    /// indicator view model so the save path is shared and can't drift.
    private func storeRecording(id: UUID, timestamp: Date, fileName: String, finalURL: URL,
                                transcription: String, status: RecordingStatus, progress: Float,
                                context: ContextSnapshot,
                                modelUsed: String?, wasFallback: Bool) async {
        // `modelUsed`/`wasFallback` are captured by the caller right after `transcribeAudio`
        // returns — NOT read here, because the `await` below can suspend long enough for another
        // transcription to overwrite them on the shared service. (parallel-recording review)
        let realDuration = await IndicatorViewModel.audioDuration(of: finalURL)
        recordingStore.addRecording(Recording(
            id: id,
            timestamp: timestamp,
            fileName: fileName,
            transcription: transcription,
            duration: realDuration,
            status: status,
            progress: progress,
            sourceFileURL: nil,
            sourceAppName: context.appName,
            sourceWindowTitle: context.windowTitle,
            sourceURL: context.fullURL,
            modelUsed: modelUsed,
            wasFallback: wasFallback))
    }

    /// Move a temp recording to its permanent location after a FAILED transcription so the audio
    /// survives and can be re-run from the history list. Returns the saved identity, or nil if the
    /// move failed (then the temp is discarded).
    private func persistFailedRecording(timestamp: Date, tempURL: URL) -> (id: UUID, timestamp: Date, fileName: String, url: URL)? {
        let id = UUID()
        let fileName = "\(Int(timestamp.timeIntervalSince1970))-\(id.uuidString.prefix(8)).wav"
        let finalURL = Recording(
            id: id,
            timestamp: timestamp,
            fileName: fileName,
            transcription: "",
            duration: 0,
            status: .failed,
            progress: 0,
            sourceFileURL: nil
        ).url
        do {
            try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)
            return (id, timestamp, fileName, finalURL)
        } catch {
            print("Failed to persist failed recording: \(error)")
            return nil
        }
    }

    /// Returns `true` when auto-paste ran but no editable field was focused, so the caller can leave
    /// the text on the clipboard and notify ⌘V. When no target is found, typing is skipped. Moved
    /// here from the indicator view model; behaviour matches master incl. the #45 clipboard restore.
    @discardableResult
    private func insertText(_ text: String) -> Bool {
        let finalText = IndicatorViewModel.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        // Optional, independent clipboard stash (never the insertion mechanism).
        if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(finalText)
        }

        guard prefs.autoPasteTranscription else { return false }

        if prefs.pasteInsteadOfTyping {
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility check
            // can't read (Messages, Electron), and is a harmless no-op otherwise. So no editable-
            // target gate — it only ever produces false negatives (#paste-messages).
            if prefs.autoCopyToClipboard {
                Diag.measure("TextInserter.paste") { TextInserter.paste() }
            } else {
                // The clipboard is only the paste vehicle here — the user opted out of keeping the
                // text on it (#44) — so put the previous contents back after the ⌘V lands.
                ClipboardUtil.borrowForPaste(finalText) {
                    Diag.measure("TextInserter.paste") { TextInserter.paste() }
                }
            }
            return false
        }

        // Typing mode: synthetic keystrokes go wherever focus is, so only type when we're confident
        // there's an editable target; otherwise stash on the clipboard and notify ⌘V.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && Diag.measure("focusedElementIsEditable") { FocusUtils.focusedElementIsEditable() } == false
        if targetMissing {
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(finalText)
            }
            return true
        }
        Diag.measure("TextInserter.type") { TextInserter.type(finalText) }
        return false
    }
}
