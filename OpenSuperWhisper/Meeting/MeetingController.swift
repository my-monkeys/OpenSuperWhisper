import AppKit
import OpenSuperWhisperCore

/// Records a meeting as two tracks, you and the call, then turns them into a timestamped
/// transcript in the history (#159). A plain transcript on purpose: summaries and action items
/// need a stronger model than the built-in one, and the transcript is what they would build on.
@MainActor
final class MeetingController: ObservableObject {
    static let shared = MeetingController()

    enum State: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(done: Int, of: Int)
    }

    @Published private(set) var state: State = .idle

    /// The history row's source, which is also how a meeting row is told from a dictation.
    static let sourceName = "Meeting"
    static let didChangeNotification = Notification.Name("MeetingStateDidChange")

    private var folder: URL?
    private var microphone: MeetingMicrophone?
    private var systemAudio: AnyObject?
    private var startedAt = Date()

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .transcribing: break
        }
    }

    func start() {
        guard #available(macOS 14.4, *) else {
            IndicatorWindowManager.shared.flash(.error(String(localized: "Meeting recording needs macOS 14.4 or later")))
            return
        }
        let folder = AppIdentity.storageRoot()!.appendingPathComponent("meetings/\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The microphone chosen in the app, as a dictation uses it.
            if let mic = MicrophoneService.shared.getActiveMicrophone() {
                _ = MicrophoneService.shared.setAsSystemDefaultInput(mic)
            }
            let microphone = MeetingMicrophone()
            try microphone.start(writingTo: MeetingTrackWriter(url: folder.appendingPathComponent("me.caf")))
            let tap = SystemAudioTap()
            do {
                try tap.start(writingTo: MeetingTrackWriter(url: folder.appendingPathComponent("others.caf")))
            } catch {
                microphone.stop()
                throw error
            }
            self.microphone = microphone
            self.systemAudio = tap
            self.folder = folder
            startedAt = Date()
            setState(.recording(since: startedAt))
            Diag.mark("meeting started in \(folder.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: folder)
            IndicatorWindowManager.shared.flash(.error(error.localizedDescription))
        }
    }

    func stop() {
        guard isRecording, let folder else { return }
        microphone?.stop()
        if #available(macOS 14.4, *) { (systemAudio as? SystemAudioTap)?.stop() }
        microphone = nil
        systemAudio = nil
        let duration = Date().timeIntervalSince(startedAt)
        Diag.mark("meeting stopped after \(Int(duration))s")
        Task { await transcribe(folder: folder, startedAt: startedAt, duration: duration) }
    }

    // MARK: - Transcript

    private struct Passage {
        let speaker: MeetingTranscript.Speaker
        let track: URL
        let range: ClosedRange<TimeInterval>
    }

    private func transcribe(folder: URL, startedAt: Date, duration: TimeInterval) async {
        let me = folder.appendingPathComponent("me.caf")
        let others = folder.appendingPathComponent("others.caf")
        let passages = Self.passages(me: me, others: others)
        setState(.transcribing(done: 0, of: passages.count))

        var utterances: [MeetingTranscript.Utterance] = []
        for (index, passage) in passages.enumerated() {
            if let text = await transcribe(passage, in: folder) {
                utterances.append(.init(speaker: passage.speaker, start: passage.range.lowerBound,
                                        end: passage.range.upperBound, text: text))
            }
            setState(.transcribing(done: index + 1, of: passages.count))
        }

        let transcript = MeetingTranscript.markdown(
            MeetingTranscript.merged(utterances), startedAt: startedAt, duration: duration,
            me: String(localized: "Me"), others: String(localized: "Others"))
        await save(transcript, me: me, others: others, startedAt: startedAt, duration: duration)
        try? FileManager.default.removeItem(at: folder)
        setState(.idle)
    }

    private static func passages(me: URL, others: URL) -> [Passage] {
        [(MeetingTranscript.Speaker.me, me), (.others, others)].flatMap { speaker, track in
            let levels = (try? MeetingTrackReader.levels(of: track)) ?? []
            return MeetingTranscript.passages(levels: levels).map { Passage(speaker: speaker, track: track, range: $0) }
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func transcribe(_ passage: Passage, in folder: URL) async -> String? {
        let clip = folder.appendingPathComponent("clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: clip) }
        do {
            try MeetingTrackReader.writeClip(try MeetingTrackReader.samples(of: passage.track, in: passage.range), to: clip)
            let text = try await TranscriptionService.shared.transcribeAudio(url: clip, settings: Settings())
            let trimmed = AppPreferences.shared.cleanTranscription(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == TranscriptionResult.noSpeech ? nil : trimmed
        } catch {
            Diag.mark("meeting passage at \(Int(passage.range.lowerBound))s failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ transcript: String, me: URL, others: URL, startedAt: Date, duration: TimeInterval) async {
        let id = UUID()
        let fileName = "meeting-\(Int(startedAt.timeIntervalSince1970))-\(id.uuidString.prefix(8)).wav"
        let recording = Recording(id: id, timestamp: startedAt, fileName: fileName, transcription: transcript,
                                  duration: duration, status: .completed, progress: 1,
                                  sourceAppName: Self.sourceName,
                                  modelUsed: ModelCatalog.activeOption()?.displayName,
                                  rawTranscription: transcript)
        do {
            try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
            try MeetingTrackReader.mix(me, others, to: recording.url)
        } catch {
            Diag.mark("meeting mix failed: \(error.localizedDescription)")
        }
        guard AppPreferences.shared.saveTranscriptionHistory else {
            try? FileManager.default.removeItem(at: recording.url)
            ClipboardUtil.copyToClipboard(transcript)
            IndicatorWindowManager.shared.flash(.info(String(localized: "Meeting transcript copied to the clipboard")))
            return
        }
        RecordingStore.shared.addRecording(recording)
        PostRecordHook.runIfEnabled(text: transcript, rawText: transcript, bundleID: nil,
                                    audioPath: recording.url.path, timestamp: startedAt, duration: duration)
        IndicatorWindowManager.shared.flash(.info(String(localized: "Meeting transcript ready on Home")))
    }

    private func setState(_ state: State) {
        self.state = state
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
