import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The Report card's draft (#168): when it can be saved, and the dictionary entry its word
/// fields make.
final class ReportDraftTests: XCTestCase {

    private func recording() -> Recording {
        Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_760_000_000), fileName: "a.wav",
                  transcription: "Send the mockups.", duration: 3, status: .completed, progress: 1,
                  modelUsed: "Parakeet v3", rawTranscription: "send the mock ups")
    }

    func testSavingNeedsAProblem() {
        var draft = ReportDraft(comment: "Something is off")
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.report(for: recording(), languageSetting: "en", appDetails: "x"))

        draft.problem = .other
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.report(for: recording(), languageSetting: "en", appDetails: "x")?.problem, .other)
    }

    func testWordFieldsOnlyForAWordOrAName() {
        XCTAssertEqual(TranscriptionReport.Problem.offered.filter { ReportDraft(problem: $0).showsWordFields },
                       [.wrongWord, .wrongName])
        XCTAssertFalse(ReportDraft().showsWordFields)
    }

    /// Words typed before switching to another problem do not ride along into its report.
    func testOtherProblemsKeepNoWords() throws {
        let draft = ReportDraft(problem: .wrongLanguage, writtenAs: "mock ups", shouldBe: "mockups")

        let report = try XCTUnwrap(draft.report(for: recording(), languageSetting: "fr", appDetails: "x"))

        XCTAssertNil(report.writtenAs)
        XCTAssertNil(report.shouldBe)
        XCTAssertEqual(report.languageSetting, "fr")
        XCTAssertNil(draft.dictionaryEntry)
    }

    func testBothWordsMakeACorrection() throws {
        let draft = ReportDraft(problem: .wrongWord, writtenAs: " mock ups ", shouldBe: " mockups ")

        let entry = try XCTUnwrap(draft.dictionaryEntry)

        XCTAssertEqual(entry.original, "mock ups")
        XCTAssertEqual(entry.replacement, "mockups")
        XCTAssertEqual(entry.kind, .correction)
        XCTAssertEqual(CustomDictionary.apply("send the mock ups", entries: [entry]), "send the mockups")
    }

    /// Without "Written as", or with the same word in another case, it is a new word, as the
    /// Dictionary page makes one.
    func testOnlyTheRightSpellingMakesANewWord() throws {
        for writtenAs in ["", "  ", "kubectl", "KUBECTL"] {
            let draft = ReportDraft(problem: .wrongName, writtenAs: writtenAs, shouldBe: "kubectl")
            let entry = try XCTUnwrap(draft.dictionaryEntry, writtenAs)
            XCTAssertEqual(entry.kind, .word, writtenAs)
            XCTAssertEqual(entry.triggers, ["kubectl"], writtenAs)
        }
    }

    func testNoEntryWithoutTheRightSpelling() {
        XCTAssertNil(ReportDraft(problem: .wrongWord, writtenAs: "mock ups", shouldBe: " ").dictionaryEntry)
    }

    /// A rule that already writes the word takes the new phrasing; nothing else moves.
    func testAddingFoldsIntoTheRuleThatWritesTheSameWord() {
        let other = CustomDictionaryEntry(original: "open ai", replacement: "OpenAI")
        let existing = CustomDictionaryEntry(original: "mockups", replacement: "mockups")
        let pattern = CustomDictionaryEntry(original: "mock(s)?", replacement: "mockups", isRegex: true)

        let result = ReportDraft.adding(CustomDictionaryEntry(original: "mock ups", replacement: "mockups"),
                                        to: [other, pattern, existing])

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], other)
        XCTAssertEqual(result[1], pattern, "a pattern writing the same thing is not the same rule")
        XCTAssertEqual(result[2].id, existing.id)
        XCTAssertEqual(result[2].triggers, ["mockups", "mock ups"])
    }

    func testAddingANewWordAppendsIt() {
        let other = CustomDictionaryEntry(original: "open ai", replacement: "OpenAI")
        let entry = CustomDictionaryEntry(original: "kubectl", replacement: "kubectl")

        XCTAssertEqual(ReportDraft.adding(entry, to: [other]), [other, entry])
        XCTAssertEqual(ReportDraft.adding(entry, to: [other, entry]), [other, entry], "already there")
    }
}

/// The prefilled GitHub issue (#168), built without opening anything.
final class ReportIssueLinkTests: XCTestCase {

    private func report(final: String = "Send the mockups & the plan + notes.",
                        raw: String? = "send the mock ups and the plan plus notes",
                        comment: String = "It wrote mock ups.\nTwice.",
                        status: RecordingStatus = .completed,
                        timing: DictationTiming? = nil) -> TranscriptionReport {
        var recording = Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_760_000_000), fileName: "a.wav",
                                  transcription: final, duration: 4.25, status: status, progress: 1,
                                  sourceAppName: "Slack", sourceWindowTitle: "#secret-project",
                                  modelUsed: "Parakeet v3", wasFallback: true, rawTranscription: raw)
        recording.timingJSON = timing?.encoded
        return TranscriptionReport(recording: recording, problem: .wrongWord, comment: comment,
                                   writtenAs: "mock ups", shouldBe: "mockups", languageSetting: "en",
                                   appDetails: "OpenSuperWhisper 0.14.2 (65) · macOS 26.2 · Apple Silicon")
    }

    private func query(of url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
    }

    func testLinkOpensANewIssueOnTheRepository() throws {
        let url = ReportIssueLink.url(for: report())

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/my-monkeys/OpenSuperWhisper/issues/new")
        XCTAssertEqual(Set(try query(of: url).keys), ["title", "body"])
        XCTAssertEqual(try query(of: url)["title"], "Transcription report: wrong word (Parakeet v3)")
    }

    /// "+" read back as a space, or "&" ending the body, would garble what the user dictated.
    func testEveryCharacterOfTheTextsSurvivesTheLink() throws {
        let url = ReportIssueLink.url(for: report())

        XCTAssertFalse(url.absoluteString.contains("+"))
        let body = try XCTUnwrap(try query(of: url)["body"])
        XCTAssertEqual(body, ReportIssueLink.body(for: report()))
        XCTAssertTrue(body.contains("Send the mockups & the plan + notes."))
    }

    func testBodyCarriesBothTextsTheModelAndNoAudio() {
        let body = ReportIssueLink.body(for: report())

        XCTAssertTrue(body.contains("**What went wrong:** Wrong word"))
        XCTAssertTrue(body.contains("**Should be:** mockups"))
        XCTAssertTrue(body.contains("**Written as:** mock ups"))
        XCTAssertTrue(body.contains("> It wrote mock ups.\n> Twice."))
        XCTAssertTrue(body.contains("- Model: Parakeet v3 (local fallback"))
        XCTAssertTrue(body.contains("- Language setting: en"))
        XCTAssertTrue(body.contains("- Length: 4.2 s") || body.contains("- Length: 4.3 s"))
        XCTAssertTrue(body.contains("- App: OpenSuperWhisper 0.14.2 (65)"))
        XCTAssertTrue(body.contains("~~~text\nsend the mock ups and the plan plus notes\n~~~"))
        XCTAssertTrue(body.contains("~~~text\nSend the mockups & the plan + notes.\n~~~"))
        XCTAssertTrue(body.contains("The audio is not attached"))
    }

    /// Where it was dictated is private, and the report never kept it.
    func testBodyLeavesOutWhereItWasDictated() {
        let body = ReportIssueLink.body(for: report())
        XCTAssertFalse(body.contains("Slack"))
        XCTAssertFalse(body.contains("secret-project"))
    }

    /// The maintainer reads the wait, stage by stage, in the same line order the contract fixes.
    /// The engine split is nested because both spans are measured inside `transcribe`.
    func testBodyCarriesTheTimingBreakdownAfterTheLength() throws {
        var timing = DictationTiming()
        timing.finalizeMs = 100
        timing.queueWaitMs = 200
        timing.engineWaitMs = 0
        timing.engineLoadMs = 400
        timing.transcribeMs = 1_300
        timing.cleanupMs = 600
        timing.insertMs = 100
        timing.totalMs = 4_300
        timing.transcribeAttempts = 1
        timing.machine = MachineState(thermalState: "nominal", lowPowerMode: false, loadAverage1m: nil)

        let body = ReportIssueLink.body(for: report(timing: timing))

        XCTAssertTrue(body.contains("- Timing: total 4.3 s (finalize 0.1, queue 0.2, "
            + "transcribe 1.3 [engine wait 0.0, model load 0.4], cleanup 0.6, insert 0.1) · "
            + "attempts 1 · thermal nominal · low power off · ended insertion · "
            + "measured at dictation time"))
        let length = try XCTUnwrap(body.range(of: "- Length:"))
        let timingLine = try XCTUnwrap(body.range(of: "- Timing:"))
        let app = try XCTUnwrap(body.range(of: "- App:"))
        XCTAssertLessThan(length.lowerBound, timingLine.lowerBound)
        XCTAssertLessThan(timingLine.lowerBound, app.lowerBound)
    }

    /// "Not measured" is a fact, not a zero: rows older than the column, imports and reruns say so.
    /// No terminal point is asserted for a row whose measurement is absent.
    func testBodySaysNotMeasuredWithoutTiming() {
        let body = ReportIssueLink.body(for: report())

        XCTAssertTrue(body.contains("- Timing: not measured"))
        XCTAssertFalse(body.contains("total 0.0 s"))
        XCTAssertFalse(body.contains("ended"))
        XCTAssertFalse(body.contains("measured at dictation time"))
    }

    /// A stage that did not run is an em dash; nothing is invented, and clauses with no value go.
    func testTimingStagesThatDidNotRunAreDashesAndOptionalClausesAreOmitted() {
        var timing = DictationTiming()
        timing.transcribeMs = 1_200
        timing.totalMs = 4_300

        let body = ReportIssueLink.body(for: report(timing: timing))

        XCTAssertTrue(body.contains("total 4.3 s (finalize —, queue —, "
            + "transcribe 1.2 [engine wait —, model load —], cleanup —, insert —)"))
        XCTAssertTrue(body.contains("ended no insertion"))
        XCTAssertFalse(body.contains("attempts"))
        XCTAssertFalse(body.contains("thermal"))
    }

    /// A failed dictation can be reported now: its own message is what the maintainer reads, the
    /// stages it never reached are em dashes, and the terminal point says failure.
    func testAFailedDictationIsReportedAsAFailureWithoutInventingStages() {
        var timing = DictationTiming()
        timing.finalizeMs = 100
        timing.totalMs = 15_000

        let body = ReportIssueLink.body(for: report(
            final: "Transcription failed: the server timed out. Click ↻ to try again.",
            raw: nil, status: .failed, timing: timing))

        XCTAssertTrue(body.contains("Transcription failed: the server timed out."))
        XCTAssertTrue(body.contains("ended failure"))
        XCTAssertTrue(body.contains("cleanup —, insert —"))
        XCTAssertFalse(body.contains("ended insertion"))
    }

    func testOneTextWhenTheOriginalIsTheSameOrWasNotKept() {
        let same = ReportIssueLink.body(for: report(final: "Same.", raw: "Same."))
        XCTAssertTrue(same.contains("**Final text** (same as before cleanup)"))
        XCTAssertFalse(same.contains("Before cleanup**"))

        let unknown = ReportIssueLink.body(for: report(final: "Old row.", raw: nil))
        XCTAssertTrue(unknown.contains("**Final text** (the text before cleanup was not kept)"))
    }

    func testFenceOutlastsTildesInTheText() {
        XCTAssertEqual(ReportIssueLink.fenced("a ~~~~ b"), ["~~~~~text", "a ~~~~ b", "~~~~~"])
        XCTAssertEqual(ReportIssueLink.fenced("plain"), ["~~~text", "plain", "~~~"])
    }

    /// A long dictation in a script that triples in percent-encoding still fits in the link,
    /// shortened and marked so.
    func testLongTextsAreShortenedToFitTheLink() throws {
        let long = String(repeating: "日本語のテキスト", count: 600)
        let url = ReportIssueLink.url(for: report(final: long, raw: long + "。", comment: long))

        XCTAssertLessThanOrEqual(url.absoluteString.count, ReportIssueLink.maxURLLength)
        let body = try XCTUnwrap(try query(of: url)["body"])
        XCTAssertTrue(body.contains(" […]"))
        XCTAssertTrue(body.contains("The audio is not attached"), "the end of the body survives")
    }
}

/// The reports as the app keeps them, on a scratch store (#168).
@MainActor
final class TranscriptionReportsModelTests: XCTestCase {

    private var root: URL!
    private var store: RecordingStore!
    private var model: TranscriptionReportsModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionReportsModelTests-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(storageRoot: root)
        model = TranscriptionReportsModel(store: store, appDetails: { "OpenSuperWhisper test" },
                                          languageSetting: { "de" })
    }

    override func tearDown() async throws {
        for report in (try? await store.fetchReports()) ?? [] {
            try? await store.deleteReport(report)
        }
        try? FileManager.default.removeItem(at: root)
        model = nil
        store = nil
    }

    private func recording() -> Recording {
        Recording(id: UUID(), timestamp: Date(), fileName: "missing-\(UUID().uuidString).wav",
                  transcription: "Final", duration: 1, status: .completed, progress: 1,
                  rawTranscription: "final")
    }

    func testSaveDeleteAndExport() async throws {
        try await model.save(ReportDraft(problem: .wrongName, shouldBe: "Maxim"), for: recording())
        try await model.save(ReportDraft(), for: recording())

        XCTAssertEqual(model.reports.count, 1, "a draft without a problem is not saved")
        let saved = try XCTUnwrap(model.reports.first)
        XCTAssertEqual(saved.languageSetting, "de")
        XCTAssertEqual(saved.appDetails, "OpenSuperWhisper test")
        XCTAssertEqual(saved.shouldBe, "Maxim")
        XCTAssertNil(saved.audioFileName, "the recording had no audio on disk")

        let zip = root.appendingPathComponent("reports.zip")
        try await model.export(to: zip)
        let head = try FileHandle(forReadingFrom: zip).read(upToCount: 4)
        XCTAssertEqual(head, Data([0x50, 0x4B, 0x03, 0x04]), "a zip file")

        await model.delete(saved)
        XCTAssertTrue(model.reports.isEmpty)
    }
}

/// What the history keeps of a dictation (#168): the engine's text beside the final one.
@MainActor
final class DictationOriginalTextTests: XCTestCase {

    private var scratch: ScratchPreferences!

    override func setUp() async throws {
        scratch = ScratchPreferences()
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false
        prefs.removeFillerWords = true
    }

    override func tearDown() async throws {
        scratch.restore()
        scratch = nil
    }

    /// Dictates `fallback` as a dictation rescued from the live preview (no audio, no engine,
    /// nothing pasted) and returns the row it leaves in the test history.
    private func dictate(_ fallback: String, marker: Substring) async throws -> Recording {
        DictationPipeline.shared.enqueue(tempURL: nil, startedAt: Date(), streamedFallback: fallback,
                                         context: DictationPipeline.ContextSnapshot(), modelOption: nil)
        var saved: Recording?
        for _ in 0..<300 where saved == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            saved = try await RecordingStore.shared.fetchRecordings(limit: 20, offset: 0)
                .first { $0.transcription.contains(marker) }
        }
        let recording = try XCTUnwrap(saved)
        addTeardownBlock { @MainActor in RecordingStore.shared.deleteRecording(recording) }
        return recording
    }

    /// Its filler words taken out: the row keeps both texts.
    func testTheEngineTextIsKeptBesideTheFinalOne() async throws {
        let marker = UUID().uuidString.prefix(8)

        let recording = try await dictate("um send the mock ups \(marker)", marker: marker)

        XCTAssertEqual(recording.transcription, "send the mock ups \(marker)")
        XCTAssertEqual(recording.rawTranscription, "um send the mock ups \(marker)")
        XCTAssertEqual(recording.distinctOriginal, "um send the mock ups \(marker)")
    }

    /// The spoken submit command comes off the original too: copying it back out must not bring
    /// "press enter" with it. Auto-paste is off, so no Return is pressed.
    func testTheSpokenSubmitCommandIsNotKeptInTheOriginal() async throws {
        AppPreferences.shared.submitOnVoiceCommand = true
        let marker = UUID().uuidString.prefix(8)

        let recording = try await dictate("um send the mock ups \(marker), press enter.", marker: marker)

        XCTAssertEqual(recording.transcription, "send the mock ups \(marker)")
        XCTAssertEqual(recording.rawTranscription, "um send the mock ups \(marker)")
    }
}
