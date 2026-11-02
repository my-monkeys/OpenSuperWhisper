import AppKit
import Combine
import Foundation
import OpenSuperWhisperCore

/// A dictation's audio that never reached its text: the app quit or crashed first, or the
/// transcription failed with history off, so nothing else keeps the clip.
struct UnfinishedClip: Identifiable, Equatable {
    let url: URL
    let recordedAt: Date
    let duration: TimeInterval
    var id: URL { url }
}

/// The clips of `unfinished/`, which is where every take is recorded. A take leaves it only by
/// being transcribed (it moves into the history, or goes once its text is safe), discarded on
/// purpose, or expiring. Anything still there that no part of the app owns is an interrupted
/// dictation, and Home offers to finish it.
@MainActor
final class UnfinishedDictations: ObservableObject {
    static let shared = UnfinishedDictations()

    /// A user who turned history off for privacy must not end up with audio kept for ever.
    nonisolated static let retentionDays = 7

    /// Under the storage root like the recordings folder, so a test host never sees the user's.
    nonisolated static var directory: URL {
        AppIdentity.storageRoot()!.appendingPathComponent("unfinished", isDirectory: true)
    }

    @Published private(set) var clips: [UnfinishedClip] = []
    /// Texts recovered this session, shown until dismissed. They are also on the clipboard.
    @Published private(set) var recovered: [String] = []
    /// Clips handed to the pipeline whose text has not come back yet.
    @Published private(set) var transcribing = 0

    private var drainObserver: AnyCancellable?

    private init() {}

    /// Scans now, and again whenever the pipeline has drained: that is when a clip kept after a
    /// failed transcription becomes visible, and when a recovered one is gone.
    func start() {
        Self.migrateLegacyTakes(from: Self.legacyDirectory, to: Self.directory, now: Date())
        drainObserver = DictationPipeline.shared.$isProcessing
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.transcribing = 0
                self?.refresh()
            }
    }

    /// Where takes were recorded before they moved here: the system temp folder, which survives a
    /// crash but not a reboot, and which nothing ever looked at.
    nonisolated static var legacyDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("temp_recordings", isDirectory: true)
    }

    /// Moves the takes an earlier version left in `legacy` into `directory`, so the scan treats
    /// them like any other. Only `rec-*.wav` goes: `primed.wav` is the recorder's warm-up file.
    /// Those the old folder has held for longer than the retention are deleted rather than
    /// moved, by modification date since a take's name says when it started, not when it stopped.
    /// Runs at launch, when the recorder owns none of them: it records into `directory` now.
    nonisolated static func migrateLegacyTakes(from legacy: URL, to directory: URL, now: Date) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in files where url.lastPathComponent.hasPrefix("rec-") && url.pathExtension == "wav" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            let target = directory.appendingPathComponent(url.lastPathComponent)
            if modified < cutoff || fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: url)
            } else {
                try? fileManager.moveItem(at: url, to: target)
            }
        }
    }

    func refresh() {
        var owned = DictationPipeline.shared.ownedClipNames
        if let recording = AudioRecorder.shared.currentRecordingURL {
            owned.insert(recording.lastPathComponent)
        }
        clips = Self.scan(in: Self.directory, owned: owned, now: Date())
    }

    /// Repairs, expires and lists the clips in `directory`, oldest first. Empty files and expired
    /// ones are deleted: there is nothing to offer for the first, and the second is what the
    /// retention promises. Clips named in `owned` belong to the recorder or the pipeline and are
    /// left strictly alone, since they are still being written or read.
    nonisolated static func scan(in directory: URL, owned: Set<String>, now: Date) -> [UnfinishedClip] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return files
            .filter { $0.pathExtension == "wav" && !owned.contains($0.lastPathComponent) }
            .compactMap { url -> UnfinishedClip? in
                let recordedAt = startTime(of: url)
                guard let duration = WAVHeaderRepair.repairFile(at: url), recordedAt > cutoff else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return UnfinishedClip(url: url, recordedAt: recordedAt, duration: duration)
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    /// `rec-<unix time>-<id>.wav`, as the recorder names its takes.
    private nonisolated static func startTime(of url: URL) -> Date {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        if parts.count == 3, parts[0] == "rec", let seconds = TimeInterval(parts[1]) {
            return Date(timeIntervalSince1970: seconds)
        }
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        return created ?? Date()
    }

    /// Runs the clip through the pipeline like any dictation, except that there is no app to put
    /// the text into any more: it lands on the clipboard and in the banner. The clip leaves the
    /// list now, so it cannot be started twice, and comes back if the transcription fails.
    func recover(_ clip: UnfinishedClip) {
        clips.removeAll { $0 == clip }
        transcribing += 1
        DictationPipeline.shared.enqueue(
            tempURL: clip.url, startedAt: clip.recordedAt, streamedFallback: "",
            context: DictationPipeline.ContextSnapshot(), modelOption: nil,
            onRecovered: { [weak self] text in self?.keepRecovered(text) })
    }

    func discard(_ clip: UnfinishedClip) {
        try? FileManager.default.removeItem(at: clip.url)
        clips.removeAll { $0 == clip }
    }

    func discardAll() {
        clips.forEach { try? FileManager.default.removeItem(at: $0.url) }
        clips.removeAll()
    }

    func dismissRecovered(at index: Int) {
        recovered.remove(at: index)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func keepRecovered(_ text: String) {
        copy(text)
        recovered.append(text)
    }

#if DEBUG
    func seedForSnapshot(clips: [UnfinishedClip], recovered: [String]) {
        self.clips = clips
        self.recovered = recovered
    }
#endif
}
