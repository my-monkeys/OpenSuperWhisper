import XCTest
import os
@testable import OpenSuperWhisperCore

/// What a cleanup pass reports about itself (#264, #266): ran, failed and why, or not run, for each
/// way the pass can end. A fake backend stands in for the server.
final class CleanupOutcomeTests: CoreTestCase {

    private static let input = "so this is the raw transcription of a dictation"
    private struct Boom: LocalizedError { var errorDescription: String? { "401 Invalid API key" } }

    private final class FakeBackend: LLMCleanupBackend, @unchecked Sendable {
        var isReady = true
        var enforcesLengthRatio = false
        let modelLabel = "org/fake-model"
        private let replies: OSAllocatedUnfairLock<[Result<String, Error>]>

        init(_ replies: Result<String, Error>...) {
            self.replies = OSAllocatedUnfairLock(initialState: replies)
        }

        func generate(system: String, user: String) async throws -> String {
            try replies.withLock { $0.isEmpty ? .success("") : $0.removeFirst() }.get()
        }
    }

    private var prefs: TestPreferences { CoreTestEnvironment.preferences }

    override func setUp() {
        super.setUp()
        prefs.aiPostProcessingEnabled = true
        prefs.aiPostProcessingPrompt = "OPEN"
        prefs.aiPostProcessingClosing = "CLOSE"
    }

    private func run(_ backend: FakeBackend, text: String = input, writesLists: Bool = false) async -> CleanupOutcome {
        await LLMPostProcessor.run(text, bundleID: nil, translating: false, writesLists: writesLists,
                                   style: "", backend: backend)
    }

    func testNotRunWhenCleanupAndFormattingAreOff() async {
        prefs.aiPostProcessingEnabled = false
        let outcome = await run(FakeBackend(.success("Cleaned.")))
        XCTAssertEqual(outcome, CleanupOutcome(text: Self.input, status: .notRun))
        XCTAssertNil(outcome.model)
    }

    func testNotRunForBlankText() async {
        let outcome = await run(FakeBackend(.success("Cleaned.")), text: "  \n")
        XCTAssertEqual(outcome.status, .notRun)
    }

    func testNotRunWithoutAnyPrompt() async {
        prefs.aiPostProcessingEnabled = false
        prefs.appContextFormattingEnabled = true
        let outcome = await run(FakeBackend(.success("Cleaned.")))
        XCTAssertEqual(outcome.status, .notRun, "formatting on, but no profile for this app")
    }

    func testCleanedCarriesTheModelAndTheReply() async {
        let outcome = await run(FakeBackend(.success(" Cleaned. ")))
        XCTAssertEqual(outcome, CleanupOutcome(text: "Cleaned.", status: .cleaned(model: "org/fake-model")))
        XCTAssertEqual(outcome.model, "org/fake-model")
        XCTAssertNil(outcome.failureReason)
    }

    /// A pass that found nothing to fix is still a success, which comparing raw and final cannot show.
    func testAReplyEqualToTheInputIsStillCleaned() async {
        let outcome = await run(FakeBackend(.success(Self.input)))
        XCTAssertEqual(outcome.status, .cleaned(model: "org/fake-model"))
    }

    func testBackendNotReadyFailsWithTheRawText() async {
        let backend = FakeBackend(.success("Cleaned."))
        backend.isReady = false
        let outcome = await run(backend)
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.status, .failed(model: "org/fake-model", reason: "Backend not ready"))
    }

    func testAThrownErrorFailsWithItsDescription() async {
        let outcome = await run(FakeBackend(.failure(Boom())))
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.failureReason, "401 Invalid API key")
        XCTAssertEqual(outcome.model, "org/fake-model")
    }

    func testAnEmptyReplyFails() async {
        let outcome = await run(FakeBackend(.success("  ")))
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.failureReason, "Empty reply")
    }

    func testAnEchoOfTheInstructionsFails() async {
        prefs.aiPostProcessingPrompt = LLMPostProcessor.defaultInstruction
        let outcome = await run(FakeBackend(.success(LLMPostProcessor.defaultInstruction)))
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.failureReason, "The model repeated its instructions")
    }

    func testTheLengthGuardFailsForABackendThatEnforcesIt() async {
        let backend = FakeBackend(.success(String(repeating: "blah ", count: 100)))
        backend.enforcesLengthRatio = true
        let outcome = await run(backend)
        XCTAssertEqual(outcome.text, Self.input)
        XCTAssertEqual(outcome.failureReason, "The reply was too long or too short")
    }

    /// A reply that kept the sentence next to its list is retried without lists, and the retry's
    /// outcome is the one reported.
    func testTheListRetryReportsTheSecondPass() async {
        let doubled = Self.input + "\n- " + Self.input
        let outcome = await run(FakeBackend(.success(doubled), .success("Cleaned.")), writesLists: true)
        XCTAssertEqual(outcome, CleanupOutcome(text: "Cleaned.", status: .cleaned(model: "org/fake-model")))
    }

    func testProcessIsTheTextOfTheOutcome() async {
        prefs.aiBackend = "apple"
        AppleIntelligence.replaceModelForTesting(StubOnDeviceModel(reply: .success("Cleaned.")))
        defer { AppleIntelligence.replaceModelForTesting(nil) }
        let text = await LLMPostProcessor.process(Self.input, bundleID: nil)
        let outcome = await LLMPostProcessor.processWithOutcome(Self.input, bundleID: nil)
        XCTAssertEqual(text, outcome.text)
        XCTAssertEqual(outcome.status, .cleaned(model: "Apple Intelligence"))
    }

    // MARK: - Server error messages

    func testOpenAIStyleErrorBodyYieldsItsMessage() {
        let body = Data(#"{"error":{"message":"Invalid API key","code":401}}"#.utf8)
        XCTAssertEqual(CleanupHTTPError(status: 401, body: body).errorDescription, "401 Invalid API key")
    }

    func testOllamaStyleAndBareMessagesAreRead() {
        XCTAssertEqual(CleanupHTTPError.serverMessage(in: Data(#"{"error":"model 'x' not found"}"#.utf8)),
                       "model 'x' not found")
        XCTAssertEqual(CleanupHTTPError.serverMessage(in: Data(#"{"message":"Nope"}"#.utf8)), "Nope")
    }

    func testTheMessageIsSqueezedToOneShortLine() throws {
        let long = "Line one\\n  line two " + String(repeating: "x", count: 300)
        let message = try XCTUnwrap(CleanupHTTPError.serverMessage(
            in: Data(#"{"error":{"message":"\#(long)"}}"#.utf8)))
        XCTAssertFalse(message.contains("\n"))
        XCTAssertTrue(message.hasPrefix("Line one line two"))
        XCTAssertEqual(message.count, CleanupHTTPError.maxMessageLength)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testAnUnreadableBodyFallsBackToTheStatus() {
        XCTAssertEqual(CleanupHTTPError(status: 502, body: Data("<html>Bad gateway</html>".utf8)).errorDescription,
                       "HTTP 502")
    }

    // MARK: - Connection probe

    private func status(_ code: Int, _ body: String) -> LLMStatus {
        RemoteBackend.probeStatus(code: code, body: Data(body.utf8), model: "m")
    }

    func testProbeAcceptsAChatReply() {
        XCTAssertEqual(status(200, #"{"choices":[{"message":{"content":"pong"}}]}"#), .ok)
    }

    func testProbeReportsAnUnreadable200() {
        XCTAssertEqual(status(200, "{}"), .requestFailed("Unexpected reply"))
    }

    func testProbeSeparatesAuthFromMissingModelFromTheRest() {
        XCTAssertEqual(status(401, #"{"error":{"message":"No auth credentials found"}}"#),
                       .authFailed("No auth credentials found"))
        XCTAssertEqual(status(403, "{}"), .authFailed(nil))
        XCTAssertEqual(status(404, "{}"), .modelMissing("m"))
        XCTAssertEqual(status(400, #"{"error":{"message":"x is not a valid model ID"}}"#), .modelMissing("m"))
        XCTAssertEqual(status(400, #"{"error":{"message":"max_tokens too small"}}"#),
                       .requestFailed("400 max_tokens too small"))
        XCTAssertEqual(status(429, #"{"error":{"message":"Rate limited"}}"#), .requestFailed("429 Rate limited"))
    }
}
