import Foundation

/// How much disk the recordings folder takes (#278). Counting 11,000 files takes a moment, so
/// the folder is walked once off the main actor, then kept current by the store: each save adds
/// its file, each deletion subtracts the files it removes. Increments can drift (a file removed
/// from the Finder, a write that is still in flight), so the Privacy screen recounts on appear.
@MainActor
public final class RecordingsDiskUsage: ObservableObject {
    public static let shared = RecordingsDiskUsage(directory: { Recording.recordingsDirectory })

    public struct Total: Equatable, Sendable {
        public var bytes: Int64
        public var count: Int

        public init(bytes: Int64, count: Int) {
            self.bytes = bytes
            self.count = count
        }
    }

    /// Nil until the first count finishes, so a view shows nothing rather than "0 bytes".
    @Published public private(set) var total: Total?

    private let directory: () -> URL

    public init(directory: @escaping () -> URL) {
        self.directory = directory
    }

    /// Recounts the folder from disk. Overlapping calls are harmless: the last to finish wins.
    public func refresh() async {
        let folder = directory()
        total = await Task.detached(priority: .utility) { Self.scan(folder) }.value
    }

    /// Counts the first time only; Home calls this on appear, Privacy calls `refresh()`.
    public func loadIfNeeded() async {
        if total == nil { await refresh() }
    }

    /// A recording was saved: add its file. Before the first count there is nothing to
    /// increment; the count will see the file itself.
    public func recordingSaved(at url: URL) {
        guard let size = Self.allocatedSize(of: url) else { return }
        total?.bytes += size
        total?.count += 1
    }

    /// Recordings were deleted. `removed` comes from `measure(_:)`, taken before the files went.
    public func recordingsRemoved(_ removed: Total) {
        guard let current = total else { return }
        total = Total(bytes: max(0, current.bytes - removed.bytes), count: max(0, current.count - removed.count))
    }

    /// The folder is empty after "Delete all".
    public func allRecordingsRemoved() {
        if total != nil { total = Total(bytes: 0, count: 0) }
    }

    // MARK: - Pure parts

    /// Sums the files that exist; a missing file counts for nothing.
    nonisolated public static func measure(_ urls: [URL]) -> Total {
        urls.reduce(into: Total(bytes: 0, count: 0)) { sum, url in
            guard let size = allocatedSize(of: url) else { return }
            sum.bytes += size
            sum.count += 1
        }
    }

    nonisolated public static func scan(_ folder: URL) -> Total {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return measure(urls)
    }

    /// What the file really takes on disk (rounded up to blocks), not its logical length.
    nonisolated public static func allocatedSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
              let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { return nil }
        return Int64(size)
    }

    /// "7.7 GB" in the user's language.
    nonisolated public static func sizeLabel(bytes: Int64, locale: Locale = .current) -> String {
        let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                         includesActualByteCount: false, locale: locale)
        return bytes.formatted(style)
    }
}
