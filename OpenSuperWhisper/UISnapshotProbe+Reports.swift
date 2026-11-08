#if DEBUG
import SwiftUI
import OpenSuperWhisperCore

/// The history's original text and the transcription reports (#168), on the probe's made-up
/// dictations. Reports are saved for real, in the probe's throwaway storage.
@MainActor
extension UISnapshotProbe {
    static let reportScreens: [String: () -> AnyView] = [
        "home-original": {
            FeedRow.snapshotShowsOriginals = true
            return AnyView(AppShellView(page: .home))
        },
        "home-original-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            FeedRow.snapshotShowsOriginals = true
            return AnyView(AppShellView(page: .home))
        },
        "report-card": { reportCard(stagedWord: false) },
        "report-card-word": { reportCard(stagedWord: true) },
        "report-card-word-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return reportCard(stagedWord: true)
        },
        "report-saved": {
            ReportCard.snapshotSaved = true
            return reportCard(stagedWord: true)
        },
        "report-saved-audio": {
            ReportCard.snapshotSaved = true
            ReportCard.snapshotIncludeAudio = true
            return reportCard(stagedWord: true)
        },
        "reports-list": { reportsList() },
        "reports-list-large-text": {
            AppPreferences.shared.textScale = TextScale.maximum
            return reportsList()
        },
    ]

    /// What every screen of a run starts from, so one screen's staging never leaks into the next.
    static func resetReportStaging() {
        AppNavigation.shared.closeReports()
        FeedRow.snapshotShowsOriginals = false
        ReportCard.snapshotDraft = nil
        ReportCard.snapshotSaved = false
        ReportCard.snapshotIncludeAudio = false
    }

    /// The seeded dictation the cleanup changed, read back from the store.
    static var reportedRecording: Recording? {
        let recent = try? waitFor { try await RecordingStore.shared.fetchRecordings(limit: 20, offset: 0) }
        return recent?.first { $0.distinctOriginal != nil }
    }

    private static func reportCard(stagedWord: Bool) -> AnyView {
        if stagedWord {
            ReportCard.snapshotDraft = ReportDraft(problem: .wrongWord, comment: "The engine keeps splitting this word in two.",
                                                   writtenAs: "mock ups", shouldBe: "mockups")
        }
        AppNavigation.shared.reporting = reportedRecording
        return AnyView(AppShellView(page: .home))
    }

    private static var reportsSeeded = false

    private static func reportsList() -> AnyView {
        if !reportsSeeded, let recording = reportedRecording {
            reportsSeeded = true
            let drafts = [
                ReportDraft(problem: .cleanupChangedMeaning, comment: "It turned my question into a statement."),
                ReportDraft(problem: .wrongName, writtenAs: "mock ups", shouldBe: "mockups"),
            ]
            for draft in drafts {
                _ = try? waitFor { try await TranscriptionReportsModel.shared.save(draft, for: recording) }
            }
        }
        AppNavigation.shared.openReports()
        return AnyView(AppShellView(page: .home))
    }

    /// Runs the main run loop until the async work is done: the probe draws synchronously.
    private static func waitFor<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(5)
        while result == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}
#endif
