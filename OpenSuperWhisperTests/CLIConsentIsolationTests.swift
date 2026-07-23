import XCTest

/// Maintainer review (PR #57, CHANGES_REQUESTED), lead-approved pin: the headless
/// CLI must never block on or trigger the UI consent prompt. The CLI is
/// STRUCTURALLY isolated from the consent seam — CLI.run() transcribes via
/// TranscriptionService.transcribeAudio directly and never touches
/// TranscriptionQueue (the seam's only consumer is addFileToQueue) — so it can
/// neither consult the closure nor hit the nil fail-safe's silent drop; it also
/// never persists a recording, which is what the prompt asks consent for.
/// CLI.run is `-> Never` and calls exit(), so no runtime test can invoke it; this
/// source-token pin is the executable form of the invariant: a future change
/// routing the CLI into the queue trips the test. Reads the real source via the
/// same #filePath repo-root contract as TranscriptionQueueConsentTests.
final class CLIConsentIsolationTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testCLISourceNeverReferencesConsentSeam() throws {
        let cliSourceURL = Self.repoRoot
            .appendingPathComponent("OpenSuperWhisper")
            .appendingPathComponent("CLI.swift")
        let source = try String(contentsOf: cliSourceURL, encoding: .utf8)
        XCTAssertFalse(source.isEmpty, "CLI.swift must be readable at \(cliSourceURL.path)")

        XCTAssertFalse(source.contains("TranscriptionQueue"),
                       "CLI must stay structurally isolated from TranscriptionQueue — a headless run can never consult the consent prompt")
        XCTAssertFalse(source.contains("confirmEnableHistory"),
                       "CLI must never reference the consent closure — a headless run can never trigger the consent prompt")
    }
}
