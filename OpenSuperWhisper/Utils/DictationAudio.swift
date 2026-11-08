import Foundation
import OpenSuperWhisperCore

/// A recording's audio as the feedback endpoint would receive it: the stored file, byte for byte.
struct FeedbackAttachment: Equatable {
    let filename: String
    let contentType: String
    let data: Data
}

/// What can go with a feedback message. The recording is sent as the app stored it, so the
/// developer hears the very file that was transcribed.
enum DictationAudioPolicy {
    /// The server allows 25 MB per file, 5 files per message and 100 MB per hour per IP. The decimal
    /// figure, so a megabyte-versus-mebibyte doubt never matters. At the stored 16 kHz Float32 WAV's
    /// 3.75 MB a minute, this is about 6 min 40 s of dictation.
    static let maxUploadBytes = 25_000_000

    enum Eligibility: Equatable {
        case eligible
        case tooLarge
        case noAudio
    }

    /// `fileSize` is nil when there is no file.
    static func eligibility(fileSize: Int?) -> Eligibility {
        guard let fileSize else { return .noAudio }
        return fileSize <= maxUploadBytes ? .eligible : .tooLarge
    }

    static func contentType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "mp3": "audio/mpeg"
        default: "application/octet-stream"
        }
    }
}

/// One dictation whose audio may be attached to a message, with what a list or a chip shows of it.
struct DictationAudioChoice: Identifiable, Equatable {
    static let previewWordLimit = 8

    let id: UUID
    let timestamp: Date
    let preview: String
    let duration: TimeInterval
    let fileURL: URL
    /// Nil when the file is gone.
    let fileSize: Int?

    init(id: UUID, timestamp: Date, preview: String, duration: TimeInterval, fileURL: URL, fileSize: Int?) {
        self.id = id
        self.timestamp = timestamp
        self.preview = preview
        self.duration = duration
        self.fileURL = fileURL
        self.fileSize = fileSize
    }

    init(recording: Recording, fileSize: Int?) {
        self.init(id: recording.id, timestamp: recording.timestamp,
                  preview: Self.firstWords(of: recording.transcription),
                  duration: recording.duration, fileURL: recording.url, fileSize: fileSize)
    }

    var eligibility: DictationAudioPolicy.Eligibility { DictationAudioPolicy.eligibility(fileSize: fileSize) }
    var isAttachable: Bool { eligibility == .eligible }

    static func firstWords(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let head = words.prefix(previewWordLimit).joined(separator: " ")
        return words.count > previewWordLimit ? head + "…" : head
    }

    /// The recording's file as it is on disk now, read here so the views never touch the file system.
    @MainActor
    static func forRecording(_ recording: Recording) -> DictationAudioChoice {
        DictationAudioChoice(recording: recording, fileSize: diskSize(of: recording.url))
    }

    /// The latest completed live dictations, newest first: imported files are not what a
    /// transcription bug is about.
    @MainActor
    static func recent(limit: Int = 10) async -> [DictationAudioChoice] {
        let page = (try? await RecordingStore.shared.fetchRecordings(
            filter: .dictations, limit: limit * 3, offset: 0)) ?? []
        return page.filter { $0.status == .completed }.prefix(limit).map(forRecording)
    }

    private static func diskSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

/// Reads the recording for upload. The size is checked again here: the file may have changed
/// since the list was built.
enum DictationAudioLoader {
    enum Failure: Error { case tooLarge, unreadable }

    static func load(_ audio: DictationAudioChoice) async throws -> FeedbackAttachment {
        try await Task.detached(priority: .userInitiated) {
            let data: Data
            do { data = try Data(contentsOf: audio.fileURL) } catch { throw Failure.unreadable }
            guard data.count <= DictationAudioPolicy.maxUploadBytes else { throw Failure.tooLarge }
            let fileExtension = audio.fileURL.pathExtension
            return FeedbackAttachment(
                filename: "dictation-\(audio.id.uuidString).\(fileExtension)",
                contentType: DictationAudioPolicy.contentType(forExtension: fileExtension),
                data: data)
        }.value
    }
}
