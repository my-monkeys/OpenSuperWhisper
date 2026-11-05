import Foundation
import XCTest

/// The structural half of #89: no file that can open an outbound connection may even name the
/// field-context types.
///
/// This is a source scan, not a runtime assertion, and it lives in the hosted target because it
/// reads the checkout from the build machine. The core suite runs on an iOS simulator too, where
/// those paths are not there to read — a scan that quietly found nothing would report success,
/// which is the failure this test exists to catch.
///
/// WHAT IT PROVES: no network-capable file mentions the context types, and the set of
/// network-capable files is exactly the reviewed list below. WHAT IT CANNOT PROVE: that the text
/// cannot leave by some route this scan does not know about — a sink using another transport, a
/// rename of the data, or data moved between allowed files. The live defence is the conformance
/// cut (`TranscriptionService.transcribe` simply does not pass the argument to a non-conforming
/// engine), and that is pinned by type, not by this scan. The remaining obligation is review:
/// any new engine or sink has to be read against `FieldContext` by a person.
final class FieldContextStructuralGuardTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenSuperWhisperTests
            .deletingLastPathComponent()  // repo root
    }

    private static let sourceRoots = ["OpenSuperWhisper", "OpenSuperWhisperCore/Sources"]

    /// Every file in the tree that can open a connection, reviewed once. The scan asserts
    /// EQUALITY in both directions on purpose: an unclassified new file fails, and so does an
    /// entry here that no longer makes a network call. Adding network code means adding the file
    /// to this list, which is the review step.
    private static let reviewedNetworkFiles: Set<String> = [
        "OpenSuperWhisper/RemoteCleanupSettingsView.swift",
        "OpenSuperWhisper/RemoteServerSettingsView.swift",
        "OpenSuperWhisper/Utils/FeedbackSender.swift",
        "OpenSuperWhisper/Utils/GitHubSettingsSync.swift",
        "OpenSuperWhisper/Utils/UpdateChecker.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Engines/RemoteEngine.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Engines/SenseVoiceModelManager.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/LLMModelManager.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/OllamaBackend.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/RemoteBackend.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/WhisperModelManager.swift",
    ]

    /// What a call looks like, rather than the bare type name: a comment saying "URLSession"
    /// should not classify a file, and four of these files were almost misclassified that way.
    private static let networkTokens = [
        "URLSession.shared", "URLSession(", ".dataTask(",
        "data(for:", "upload(for:", "download(for:",
    ]

    /// Names that carry — or could carry — the focused field's text. None may appear in a file
    /// that can reach the network, whatever the engine's capability says.
    private static let contextIdentifiers = [
        "FieldContext", "proseContext", "focusedText", "fieldTerms", "surroundingText",
        "ProseContextEngine", "TermContextEngine",
        // The parameter the text actually travels in. It contains none of the names above —
        // "capturedFieldText" does not contain "focusedText" — so a network file could take it
        // and the scan would have stayed green. Added after the security review found it.
        "capturedFieldText",
    ]

    // MARK: - The scan

    private func sources() throws -> [String: String] {
        var found: [String: String] = [:]
        let manager = FileManager.default
        for root in Self.sourceRoots {
            let base = repoRoot.appendingPathComponent(root)
            XCTAssertTrue(manager.fileExists(atPath: base.path),
                          "source root not found: \(base.path)")
            guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                found[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }

    /// Everything that can open a connection, by path relative to the repo root.
    private func networkFiles(in sources: [String: String]) -> Set<String> {
        Set(sources.filter { _, text in
            Self.networkTokens.contains { text.contains($0) }
        }.keys)
    }

    // MARK: - Tests

    /// The positive control. A scan that read no files, or looked in the wrong root, passes every
    /// absence assertion below while proving nothing; this makes that a red test instead.
    func testTheScanReachesTheSourcesItClaims() throws {
        let sources = try sources()

        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files to mean anything")
        XCTAssertNotNil(sources["OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Engines/RemoteEngine.swift"])
        XCTAssertNotNil(sources["OpenSuperWhisper/Utils/SourceCapture.swift"])
        XCTAssertFalse(networkFiles(in: sources).isEmpty, "no network file matched: the tokens rotted")
    }

    /// Every file that can reach the network is on the reviewed list, and the list holds nothing
    /// that stopped being one.
    func testEveryNetworkFileIsReviewed() throws {
        let found = networkFiles(in: try sources())

        let unreviewed = found.subtracting(Self.reviewedNetworkFiles).sorted()
        XCTAssertTrue(unreviewed.isEmpty,
                      "unreviewed network-capable file(s): \(unreviewed.joined(separator: ", "))")

        let stale = Self.reviewedNetworkFiles.subtracting(found).sorted()
        XCTAssertTrue(stale.isEmpty,
                      "reviewed file(s) no longer make a network call: \(stale.joined(separator: ", "))")
    }

    /// The load-bearing clause. A remote sink that cannot name `FieldContext` cannot be handed
    /// one without someone editing this list.
    func testNoNetworkFileNamesTheFieldContextTypes() throws {
        let sources = try sources()
        let found = networkFiles(in: sources)
        XCTAssertFalse(found.isEmpty, "no network file matched: this assertion would be vacuous")

        var offenders: [String] = []
        for path in found.sorted() {
            guard let text = sources[path] else { continue }
            for identifier in Self.contextIdentifiers where text.contains(identifier) {
                offenders.append("\(path): \(identifier)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a network-capable file names the field context: \(offenders.joined(separator: "; "))")
    }

    /// `FieldContextCleanupPrivacyTests` inspects `RemoteBackend.request(for:system:)`. That test
    /// is worthless if `generate` builds its own copy of the request — it would be inspecting a
    /// function nothing calls.
    ///
    /// The declaration spells the label with a space (`func request(for user: String, …)`); only
    /// a call site produces the literal `request(for:`. So one occurrence means the call exists,
    /// and zero means the seam was inlined and the cleanup privacy test has become dead code.
    func testTheCleanupSendUsesTheInspectedBuilder() throws {
        let path = "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/RemoteBackend.swift"
        let all = try sources()
        let text = try XCTUnwrap(all[path])

        let callSites = text.components(separatedBy: "request(for:").count - 1
        XCTAssertGreaterThanOrEqual(callSites, 1,
                                    "generate no longer calls request(for:system:): the cleanup privacy test inspects dead code")
    }

    /// The secure-field predicate is tested on its own; nothing checked that the readers ask it.
    /// `SecureTextFields` states that "the three readers that feed a model all ask here", so a
    /// reader that stopped calling it — or called it without negating the answer — would leave
    /// every predicate test green while reading a password box.
    ///
    /// Blind spot, stated: this covers the three files that are the readers today. A NEW reader
    /// that never calls the guard is not caught, because finding it would mean enumerating
    /// "model-facing Accessibility readers", a curated list with the same weakness as the network
    /// one above.
    func testTheThreeModelFacingReadersAskTheSecureFieldGuard() throws {
        let sources = try sources()
        let readers = [
            "OpenSuperWhisper/Utils/SourceCapture.swift",
            "OpenSuperWhisper/Utils/TextAroundCaret.swift",
            "OpenSuperWhisper/Utils/WatchedField.swift",
        ]

        for path in readers {
            let text = try XCTUnwrap(sources[path], "reader not found: \(path)")
            XCTAssertTrue(text.contains("!SecureTextFields.isSecure("),
                          "\(path) no longer refuses a secure field, or calls the guard without negating it")
        }
    }

    /// F2: the field is read only after the per-app model rule may have replaced the engine.
    ///
    /// The ordering is a convention between two adjacent lines, and the original defect was
    /// exactly a call-order mistake, so it needs a guard that is not another reading of the same
    /// two lines. Swapping them reddens this.
    ///
    /// Only the hotkey path is covered: the main window's record button calls
    /// `applyForCurrentContext` but never `captureFocusedText`, because our own window is
    /// frontmost there and `captureFrontmost` skips it — there is no ordering to pin.
    ///
    /// What this does NOT prove: that the read is skipped when the post-rule engine is remote.
    /// That needs `captureFocusedText`'s Accessibility read to be injectable, and it is a direct
    /// `SourceCapture` call today. The pure gate underneath is asserted in `FieldContextGateTests`.
    func testTheFieldIsReadAfterTheModelRule() throws {
        let path = "OpenSuperWhisper/Indicator/IndicatorWindow.swift"
        let text = try XCTUnwrap(try sources()[path])

        let rule = try XCTUnwrap(text.range(of: "ContextModelSwitcher.applyForCurrentContext()"),
                                 "the model rule is no longer applied at record start")
        let read = try XCTUnwrap(text.range(of: "RecordingContext.shared.captureFocusedText()"),
                                 "the field is no longer read at record start")
        XCTAssertLessThan(rule.lowerBound, read.lowerBound,
                          "the field is read before the per-app rule picks the engine — F2 is back")
    }
}
