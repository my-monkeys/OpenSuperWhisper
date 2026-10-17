import Combine
import Foundation
import OpenSuperWhisperCore

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
        var bundleID: String? = nil
        var windowTitle: String? = nil
        var fullURL: String? = nil
        /// What the keyboard layout resolved to when recording started, when the user asked the
        /// layout to pick the language. Carried per clip for the same reason as the rest: the
        /// layout will often have changed by the time the queue reaches this dictation (#120).
        var keyboardLanguage: String? = nil
        /// What was written in the field when recording started, when the setting asks for it.
        /// Snapshotted like the rest: by the time the queue reaches this clip the caret has
        /// usually moved, and a later recording would otherwise lend it its own field.
        var focusedText: String? = nil
        /// The field that had the focus at record start, where the text goes back to even if the
        /// user has clicked elsewhere by the time it is transcribed (#164).
        var focusTarget: FocusTarget? = nil
        /// The waiting agent this dictation answers, from the agent panel. Its text goes back
        /// to that agent instead of into the focused app.
        var agentReplyID: String? = nil
    }

    private struct PendingDictation {
        let id: UUID
        let seq: Int
        let startedAt: Date
        /// nil when the recorder captured nothing and only the live preview heard the words.
        /// Everything downstream of transcription still applies to such a dictation: the
        /// dictionary rules, the cleanup pass, insertion into the app it was dictated into. Only
        /// the audio is missing, so only the audio steps are skipped (#128).
        let tempURL: URL?
        let streamedFallback: String
        let context: ContextSnapshot
        /// Model that was active when this clip was recorded. Applied for this clip's transcription
        /// even if a later recording has since switched the global model. (#model-snapshot)
        let modelOption: DictationModelOption?
        /// This take was started by the submit mouse button, so press Return after inserting (#50).
        let submitAfterInsert: Bool
        /// The stop phrase ended this take, so it was said, and anything after it is the tail
        /// of speech the recorder caught before stopping. The text is cut at its last
        /// occurrence rather than only stripped from the very end (#145).
        let endedByStopPhrase: Bool
    }

    /// Dictations waiting in the queue plus the one currently being processed. Drives optional
    /// UI (the indicator shows the count while recording) and diagnostics.
    @Published private(set) var pendingCount = 0
    /// True while the background loop is draining the queue.
    @Published private(set) var isProcessing = false

    /// Set by `discardEverything()` and cleared once the queue drains.
    ///
    /// A dictation you have changed your mind about is worse than a slow one: it lands in
    /// whatever you were typing while you watched it come. Transcription happens off the
    /// recording, so by then there is nothing left to stop except the insertion itself.
    private var discarding = false

    /// Test seam: when set, used instead of the real engine so unit tests can exercise queue
    /// ordering / pendingCount / no-speech / failure paths without a model. nil in production.
    var transcribeOverride: ((URL, Settings) async throws -> String)?
    /// Test seams around what happens to the text after transcription, so a test can see the
    /// order of the steps without a language model, an agent or a focused field: the cleanup
    /// model's pass, the hand-off to a waiting agent (text, request id, send), and the insertion
    /// (text, submitting). nil in production.
    var cleanupOverride: ((String) async -> String)?
    var agentReplyOverride: ((String, String, Bool) -> Void)?
    var deliverOverride: ((String, Bool) async -> Delivery)?

    /// Throws away everything queued and in flight: nothing is inserted, saved, or pasted.
    ///
    /// The clip being transcribed cannot be un-transcribed, so the engine is asked to stop and
    /// whatever it returns is dropped on the floor. Anything still queued never starts.
    func discardEverything() {
        guard isProcessing || !queue.isEmpty else { return }

        discarding = true
        for item in queue {
            discardAudio(item.tempURL)
        }
        queue.removeAll()
        refreshPendingCount()
        transcriptionService.cancelTranscription()
    }

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
    func enqueue(tempURL: URL?, startedAt: Date, streamedFallback: String,
                 context: ContextSnapshot, modelOption: DictationModelOption?,
                 submitAfterInsert: Bool = false, endedByStopPhrase: Bool = false) {
        seqCounter += 1
        queue.append(PendingDictation(
            id: UUID(),
            seq: seqCounter,
            startedAt: startedAt,
            tempURL: tempURL,
            streamedFallback: streamedFallback,
            context: context,
            modelOption: modelOption,
            submitAfterInsert: submitAfterInsert,
            endedByStopPhrase: endedByStopPhrase))
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
            // Only the run that was discarded is affected; the next dictation starts clean.
            self.discarding = false
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

    /// Remove the clip, if there was one. A dictation rescued from the live preview has no file
    /// to clean up, and five call sites should not each have to say so.
    private func discardAudio(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func refreshPendingCount() {
        pendingCount = queue.count + (inFlight ? 1 : 0)
    }

    private func process(_ item: PendingDictation) async {
        var settings = Settings()
        settings.focusedText = item.context.focusedText
        // Only a dictation expands snippets, so only a dictation is biased toward their triggers.
        settings.snippetTriggers = AppPreferences.shared.dictationSnippetTriggers
        settings.selectedLanguage = KeyboardLanguage.language(for: settings.selectedLanguage,
                                                              resolved: item.context.keyboardLanguage)
        do {
            let rawText: String
            if let clip = item.tempURL {
                if let transcribeOverride {
                    rawText = try await transcribeOverride(clip, settings)
                } else {
                    rawText = try await transcriptionService.transcribeAudio(
                        url: clip, settings: settings, modelOverride: item.modelOption)
                }
            } else {
                // Nothing to transcribe, which is exactly what the branch below already handles:
                // it falls back to the live preview when the file pass comes back empty. A
                // dictation that never had a file enters through the same door.
                rawText = ""
            }
            // Which model actually produced this text — snapshot it *now*, before the LLM and
            // audio-duration awaits below. transcribeAudio has returned so these are still this
            // item's values, but its engine gate is already released: during those awaits a
            // file-drop/rerun transcription could acquire the gate and overwrite
            // `lastUsedModel`/`lastUsedFallback`, mislabeling this history row. (parallel-recording review)
            // Checked after the engine returns rather than before: a cancelled transcription
            // still comes back here, and this is the last point before the text reaches the
            // user's document. Nothing is saved or inserted.
            if discarding {
                discardAudio(item.tempURL)
                return
            }

            let modelUsed = transcriptionService.lastUsedModel?.displayName ?? ModelCatalog.activeOption()?.displayName
            let wasFallback = transcriptionService.lastUsedFallback
            // The stop phrase goes first, before the dictionary rules can reshape it. (#145)
            let spokenText = AppPreferences.shared.stripStopPhrase(rawText, cutAtLast: item.endedByStopPhrase)
            var text = AppPreferences.shared.cleanTranscription(spokenText)
            // The engine's own output (its dictionary rules already applied inside the engine),
            // before filler-word removal and any LLM cleanup, kept for the post-record hook and
            // the history's original text (#168). Tracked alongside `text` rather than read from
            // `rawText` at the end, because the short-clip fallback below replaces the basis
            // of the text entirely — handing a hook "No speech detected" for a clip that
            // produced words would be worse than not telling it at all.
            var engineText = spokenText

            // File pass found nothing. Fall back to the live preview if it caught the words (short
            // clip); only with neither is it genuinely "no speech" — then drop it (no empty
            // recording) and surface a brief notice. (#short-dictation)
            if text == TranscriptionResult.noSpeech
                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let streamed = AppPreferences.shared.stripStopPhrase(item.streamedFallback,
                                                                     cutAtLast: item.endedByStopPhrase)
                let fallback = AppPreferences.shared
                    .cleanTranscription(streamed)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fallback.isEmpty else {
                    discardAudio(item.tempURL)
                    IndicatorWindowManager.shared.flash(.info("No speech detected"))
                    return
                }
                text = fallback
                engineText = streamed
            }

            // Optional LLM cleanup (no-op when disabled; returns the raw text on failure). The
            // app-aware formatting rules are keyed off the app that was frontmost when the clip was
            // RECORDED — the app the user was dictating into — not whatever is frontmost now that
            // the background queue got to it. (parallel-recording)
            if let cleanupOverride {
                text = await cleanupOverride(text)
            } else {
                text = await LLMPostProcessor.process(
                    text, bundleID: item.context.bundleID, translating: settings.translateToEnglish,
                    writesLists: RichListPaste.cleanupWritesLists(into: item.context.bundleID),
                    style: AppPreferences.shared.writingStyle(for: item.context.bundleID).instructions)
            }

            // Trailing "press enter" voice command (opt-in): strip it and remember to press Return
            // after insertion, submitting the message/prompt.
            let (strippedText, spokenSubmit) = AppPreferences.shared.stripSubmitCommand(text)
            text = strippedText
            // Snippets last, on what the cleanup model returned, so it cannot rewrite them, and
            // after the submit command, so a snippet whose text ends in "press enter" keeps it.
            // (#167)
            text = AppPreferences.shared.expandSnippets(text)
            // Either route asks for the same thing: send Return once the text is in.
            let shouldSubmit = spokenSubmit || item.submitAfterInsert
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

                // A rescued dictation has no audio to move. The row is still worth keeping: the
                // text is what the user dictated, and a history entry without a clip beats losing
                // the words. The hook is told there is no audio, exactly as it already is when
                // history is off.
                if let clip = item.tempURL {
                    try recorder.moveTemporaryRecording(from: clip, to: finalURL)
                    hookAudioPath = finalURL.path
                }

                // Without the spoken submit command, like the text itself: copying the original
                // back out of the history must not bring "press enter" with it.
                let original = AppPreferences.shared.stripSubmitCommand(engineText).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await storeRecording(
                    id: recordingId, timestamp: timestamp, fileName: fileName,
                    finalURL: finalURL, transcription: text, rawTranscription: original.isEmpty ? nil : original,
                    status: .completed, progress: 1.0, context: item.context,
                    modelUsed: modelUsed, wasFallback: wasFallback)
            } else {
                discardAudio(item.tempURL)
            }

            // An answer to a waiting agent goes back to it, not into whatever has the cursor.
            if let replyID = item.context.agentReplyID {
                if hasText {
                    if let agentReplyOverride {
                        agentReplyOverride(text, replyID, shouldSubmit)
                    } else {
                        AgentInbox.shared.receiveDictation(text, for: replyID, send: shouldSubmit)
                    }
                    // Never inserted, but newer all the same: the paste-last shortcut must not
                    // fall back to an older paste that missed.
                    TranscriptInserter.noteNewerTranscription()
                }
                return
            }

            let delivery: Delivery
            let submitting = shouldSubmit && AppPreferences.shared.autoPasteTranscription
            if hasText, let deliverOverride {
                delivery = await deliverOverride(text, submitting)
            } else if hasText {
                delivery = await deliver(text, context: item.context,
                                         language: settings.translateToEnglish ? "en" : settings.selectedLanguage,
                                         submitting: submitting)
            } else if shouldSubmit {
                delivery = await deliverSubmitOnly(context: item.context)
            } else {
                delivery = .inserted
            }
            if hasText {
                PostRecordHook.runIfEnabled(text: text, rawText: engineText,
                                            bundleID: item.context.bundleID,
                                            audioPath: hookAudioPath,
                                            timestamp: item.startedAt, duration: 0)
            }

            // Submit only when auto-paste actually inserted text somewhere. A short settle delay lets
            // the pasted text land in the field before Return reaches it. A paste in pieces takes
            // seconds, long enough to throw the dictation away while it goes in (#165): what is
            // in the field then stays there, unsent.
            if shouldSubmit && AppPreferences.shared.autoPasteTranscription && delivery == .inserted
                && !discarding {
                try? await Task.sleep(nanoseconds: 120_000_000)
                TextInserter.pressReturn()
            }

            // No editable target was found, or the app it was dictated into has gone — the text is
            // on the clipboard; tell the user to paste it.
            if delivery == .onClipboardAnnounced {
                IndicatorWindowManager.shared.flash(.info("Copied — press ⌘V to paste"))
            }
        } catch {
            print("Dictation transcription failed: \(error)")
            // Don't lose the audio on failure. When history is on, keep the recording with a .failed
            // status + retry message so it shows in the log and can be re-run with the regenerate (↻)
            // button. Otherwise discard. Either way, surface the failure — silent loss is worse.
            if AppPreferences.shared.saveTranscriptionHistory,
               let clip = item.tempURL,
               let saved = persistFailedRecording(timestamp: item.startedAt, tempURL: clip) {
                await storeRecording(
                    id: saved.id, timestamp: saved.timestamp, fileName: saved.fileName,
                    finalURL: saved.url, transcription: "Transcription failed — click ↻ to try again.",
                    rawTranscription: nil, status: .failed, progress: 0, context: item.context,
                    modelUsed: nil, wasFallback: false)
            } else {
                discardAudio(item.tempURL)
            }
            IndicatorWindowManager.shared.flash(.error("Transcription failed"))
        }
    }

    /// Insert a recording (already at its final URL) into the store with the measured audio duration
    /// and the captured source context (app / window / URL / model used). Moved here from the
    /// indicator view model so the save path is shared and can't drift.
    private func storeRecording(id: UUID, timestamp: Date, fileName: String, finalURL: URL,
                                transcription: String, rawTranscription: String?,
                                status: RecordingStatus, progress: Float,
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
            wasFallback: wasFallback,
            rawTranscription: rawTranscription))
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

    /// Where a finished dictation went, which decides whether Return follows and what is said.
    enum Delivery: Equatable {
        /// Inserted, or left alone because auto-paste is off.
        case inserted
        /// On the clipboard for a manual ⌘V, and the user is told so.
        case onClipboardAnnounced
        /// Not inserted, with the warning off: held for the paste-last shortcut. Or only in part
        /// (#165), the rest held the same way unless a newer dictation took over or this one was
        /// thrown away; anything worth saying about it is already said.
        case held
    }

    /// Puts the focus back in the field the dictation started in, then inserts (#164).
    ///
    /// - Parameters:
    ///   - language: what the text is written in, for fitting it to the field (#163).
    ///   - submitting: Return follows the insertion, which keeps a list paste plain (#166).
    private func deliver(_ text: String, context: ContextSnapshot, language: String,
                         submitting: Bool) async -> Delivery {
        let prefs = AppPreferences.shared
        return await Self.deliver(
            to: context.focusTarget,
            returningFocus: prefs.autoPasteTranscription && prefs.pasteIntoOriginalField,
            warn: prefs.notifyWhenNoPasteTarget,
            keepOnClipboard: prefs.autoCopyToClipboard,
            bringBack: { await FocusReturn.bringBack($0) },
            hold: { TranscriptInserter.holdUndelivered(IndicatorViewModel.applyPostProcessing(text),
                                                       onClipboard: $0) },
            insert: { await self.insertText(text, context: context, language: language,
                                            submitting: submitting) })
    }

    /// A dictation that is only the spoken submit command presses Return in the app it started
    /// in, like any text would go there, and not at all when that app cannot be brought back.
    private func deliverSubmitOnly(context: ContextSnapshot) async -> Delivery {
        let prefs = AppPreferences.shared
        return await Self.deliverSubmitOnly(
            to: context.focusTarget,
            returningFocus: prefs.autoPasteTranscription && prefs.pasteIntoOriginalField,
            bringBack: { await FocusReturn.bringBack($0) })
    }

    /// `.held` when Return must not be pressed: there is no text to hold or announce.
    static func deliverSubmitOnly(to target: FocusTarget?, returningFocus: Bool,
                                  bringBack: (FocusTarget) async -> FocusReturn.Outcome) async -> Delivery {
        await deliver(to: target, returningFocus: returningFocus, warn: false, keepOnClipboard: false,
                      bringBack: bringBack, hold: { _ in }, insert: { .inserted })
    }

    /// The delivery with the system passed in, so tests can run it without moving the focus or
    /// posting a keystroke.
    ///
    /// - Parameters:
    ///   - returningFocus: the setting is on and the text is going to be inserted at all. With
    ///     auto-paste off nothing would follow the focus change, and pulling the user back to
    ///     another app for nothing is worse than leaving them where they are.
    ///   - hold: keeps the text for a manual paste, on the clipboard when passed `true`.
    ///   - insert: the usual insertion, and where it left the text.
    static func deliver(to target: FocusTarget?, returningFocus: Bool, warn: Bool,
                        keepOnClipboard: Bool,
                        bringBack: (FocusTarget) async -> FocusReturn.Outcome,
                        hold: (_ onClipboard: Bool) -> Void,
                        insert: () async -> Delivery) async -> Delivery {
        if returningFocus, let target {
            let outcome = await bringBack(target)
            Diag.mark("focus return before insertion: \(outcome)")
            if outcome == .unreachable {
                hold(warn || keepOnClipboard)
                return warn ? .onClipboardAnnounced : .held
            }
        }
        return await insert()
    }

    /// Inserts through `TranscriptInserter`, where the insertion policy lives, shared with the
    /// re-paste shortcut. A paste in pieces that stopped part way is `.held`: Return must not
    /// send the half that went in (#165). It stops too once the dictation is thrown away.
    private func insertText(_ text: String, context: ContextSnapshot, language: String,
                            submitting: Bool) async -> Delivery {
        let prefs = AppPreferences.shared
        let fitToField = prefs.autoPasteTranscription && prefs.matchTextAroundCaret
        let prepared = TranscriptInserter.prepared(text, fitToField: fitToField, language: language)
        let insertion = await TranscriptInserter.insert(
            prepared,
            honorAutoPastePreference: true, targetBundleID: context.bundleID,
            windowTitle: context.windowTitle, submitting: submitting, wanted: { !discarding })
        switch insertion {
        case .done:
            // Text that Return is about to send never stays in the field to be corrected (#169).
            if prefs.autoPasteTranscription && !submitting {
                CorrectionWatch.begin(after: prepared.fitted, pid: context.focusTarget?.pid, language: language)
            }
            return .inserted
        case .onClipboard: return .onClipboardAnnounced
        case .cutShort: return .held
        }
    }
}
