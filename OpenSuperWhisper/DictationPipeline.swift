import Combine
import Foundation

/// Runs hotkey dictations (transcribe → save → paste) on a background, serial queue so the
/// user is never blocked from starting the next recording while a previous one is still being
/// transcribed. Items are processed strictly in recording-start order, so their pasted text
/// lands in the same order the clips were recorded — recording is decoupled from transcription,
/// but the *output* order is preserved.
///
/// Why serial and not truly concurrent: `TranscriptionService.shared` is a single `@MainActor`
/// engine with per-run state (`isTranscribing`/`progress`/`transcriptionTask`/`lastUsedModel`),
/// so two transcriptions can't safely run through it at once. Serial FIFO draining gives the
/// behaviour that actually matters here — recording continues freely in the foreground while
/// transcription catches up in the background — and makes ordered paste automatic. Reading
/// `lastUsedModel`/`lastUsedFallback` right after each `transcribeAudio` is only correct because
/// no other transcription can interleave.
@MainActor
final class DictationPipeline: ObservableObject {
    static let shared = DictationPipeline()

    /// Frontmost-app context captured at record time, carried per dictation so the history row
    /// shows where THIS clip was dictated — not wherever focus happened to move by the time the
    /// clip is processed (with rapid back-to-back recordings these differ).
    struct ContextSnapshot {
        var appName: String?
        var windowTitle: String?
        var fullURL: String?
    }

    private struct PendingDictation {
        let id: UUID
        let seq: Int
        let startedAt: Date
        let tempURL: URL
        let streamedFallback: String
        let context: ContextSnapshot
    }

    /// Dictations waiting in the queue plus the one currently being processed. Drives optional
    /// UI/diagnostics; the feature works regardless of whether anything observes it.
    @Published private(set) var pendingCount = 0
    /// True while the background loop is draining the queue.
    @Published private(set) var isProcessing = false

    private var queue: [PendingDictation] = []
    private var inFlight = false
    private var seqCounter = 0
    private var loopTask: Task<Void, Never>?

    private let transcriptionService = TranscriptionService.shared
    private let recordingStore = RecordingStore.shared
    private let recorder = AudioRecorder.shared

    private init() {}

    /// Enqueue a finished recording for background transcription + paste. Returns immediately;
    /// the work drains on the serial loop. Called on the main actor from the indicator's stop
    /// handler. `seq` is monotonic and assigned here, so append order == recording-start order.
    func enqueue(tempURL: URL, startedAt: Date, streamedFallback: String, context: ContextSnapshot) {
        seqCounter += 1
        queue.append(PendingDictation(
            id: UUID(),
            seq: seqCounter,
            startedAt: startedAt,
            tempURL: tempURL,
            streamedFallback: streamedFallback,
            context: context))
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

    /// Pop the earliest-recorded pending dictation. FIFO == start order (seq is monotonic and
    /// the queue is only ever appended to on the main actor), so no explicit sort is needed.
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
        do {
            let rawText = try await transcriptionService.transcribeAudio(url: item.tempURL, settings: Settings())
            var text = AppPreferences.shared.cleanTranscription(rawText)

            // File pass found nothing. Fall back to the live preview if it caught the words (short
            // clip); only with neither is it genuinely "no speech" — then never paste the
            // placeholder, just drop it (no empty recording). (#short-dictation)
            if text == TranscriptionResult.noSpeech
                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let fallback = AppPreferences.shared
                    .cleanTranscription(item.streamedFallback)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fallback.isEmpty else {
                    try? FileManager.default.removeItem(at: item.tempURL)
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
                let timestamp = Date()
                let recordingId = item.id
                // Include the id so two dictations that finish within the same wall-clock second
                // never collide on the same on-disk file (the id is the store's primary key, the
                // filename is just where the audio lives).
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
                    status: .completed, progress: 1.0, context: item.context)
            } else {
                try? FileManager.default.removeItem(at: item.tempURL)
            }

            let pasteTargetMissing = hasText ? insertText(text) : false
            if hasText {
                PostRecordHook.runIfEnabled(text: text, audioPath: hookAudioPath, timestamp: Date(), duration: 0)
            }

            // Submit only when auto-paste actually inserted text somewhere. A short settle delay lets
            // the pasted text land in the field before Return reaches it.
            if shouldSubmit && AppPreferences.shared.autoPasteTranscription && !pasteTargetMissing {
                try? await Task.sleep(nanoseconds: 120_000_000)
                TextInserter.pressReturn()
            }
        } catch {
            print("Dictation transcription failed: \(error)")
            // Don't lose the audio on failure. When history is on, keep the recording with a
            // .failed status + retry message so it shows in the log and can be re-run with the
            // regenerate (↻) button. Otherwise discard.
            if AppPreferences.shared.saveTranscriptionHistory,
               let saved = persistFailedRecording(tempURL: item.tempURL) {
                await storeRecording(
                    id: saved.id, timestamp: saved.timestamp, fileName: saved.fileName,
                    finalURL: saved.url, transcription: "Transcription failed — click ↻ to try again.",
                    status: .failed, progress: 0, context: item.context)
            } else {
                try? FileManager.default.removeItem(at: item.tempURL)
            }
        }
    }

    /// Insert a recording (already at its final URL) into the store with the measured audio
    /// duration and the captured source context (app / window / URL / model used). Moved here
    /// from the indicator view model so the save path is shared and can't drift.
    private func storeRecording(id: UUID, timestamp: Date, fileName: String, finalURL: URL,
                                transcription: String, status: RecordingStatus, progress: Float,
                                context: ContextSnapshot) async {
        let realDuration = await IndicatorViewModel.audioDuration(of: finalURL)
        // The model that actually produced the text (the local fallback, not the configured
        // remote model, when the server was unreachable). Safe to read now: serial processing
        // means no other transcription ran between this item's `transcribeAudio` and here.
        let modelUsed = transcriptionService.lastUsedModel?.displayName ?? ModelCatalog.activeOption()?.displayName
        let wasFallback = transcriptionService.lastUsedFallback
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
    private func persistFailedRecording(tempURL: URL) -> (id: UUID, timestamp: Date, fileName: String, url: URL)? {
        let timestamp = Date()
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

    /// Returns `true` when auto-paste ran but no editable field was focused, so the caller can
    /// leave the text on the clipboard. When no target is found, typing is skipped. Moved here from
    /// the indicator view model; behaviour is unchanged (paste targets whatever is focused now).
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
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility
            // check can't read (Messages, Electron), and is a harmless no-op otherwise. So no
            // editable-target gate — it only ever produces false negatives (#paste-messages).
            if !prefs.autoCopyToClipboard { ClipboardUtil.copyToClipboard(finalText) }
            Diag.measure("TextInserter.paste") { TextInserter.paste() }
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
