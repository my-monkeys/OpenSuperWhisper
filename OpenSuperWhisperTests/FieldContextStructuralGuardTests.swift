import Foundation
import XCTest

/// The structural half of #89: no Swift file in the shipping sources — the app, the core and the
/// linked LiquidGlass package — that can open an outbound connection may even name the
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
/// network call whose spelling matches none of the tokens, a rename of the data, or data moved
/// between allowed files. The live defence is the conformance cut
/// (`TranscriptionService.transcribe` simply does not pass the argument to a non-conforming
/// engine), and that is pinned by type, not by this scan. The remaining obligation is review:
/// any new engine or sink has to be read against `FieldContext` by a person.
///
/// The type-level half of that defence lives in
/// `RemoteEngineRequestTests.testTheRemoteEngineConformsToNeitherContextProtocol`, not here —
/// beside the body-equality assertion whose comment cites it. A reviewer looking for it in this
/// file will not find it, and the plan once listed it under a file that was never created.
final class FieldContextStructuralGuardTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenSuperWhisperTests
            .deletingLastPathComponent()  // repo root
    }

    /// Every Swift source root the app ships. LiquidGlass is a local package linked into the app
    /// (project.pbxproj `XCLocalSwiftPackageReference`), so a sink there would run in the app just
    /// like one in `OpenSuperWhisper/`.
    private static let sourceRoots = ["OpenSuperWhisper", "OpenSuperWhisperCore/Sources",
                                      "LiquidGlass/Sources"]

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
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/OllamaThinking.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/RemoteBackend.swift",
        "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/WhisperModelManager.swift",
    ]

    /// What a call looks like, rather than the bare type name: a comment saying "URLSession"
    /// should not classify a file, and four of these files were almost misclassified that way.
    ///
    /// The classic task factories are listed beside the async ones: a new sink is as likely to be
    /// written as `session.uploadTask(with:from:)` as `try await session.upload(for:)`.
    private static let networkTokens = [
        "URLSession.shared", "URLSession(", ".dataTask(",
        "data(for:", "upload(for:", "download(for:", "uploadTask(", "downloadTask(",
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

    /// The body of the function or computed property whose signature contains `signature`,
    /// braces matched from its opening brace. `anchor` starts the search after a known marker,
    /// for a signature that appears more than once.
    ///
    /// Good enough for the bodies scanned here: none of them carries a brace inside a string
    /// literal. A body that did would need a real parser.
    private func body(of signature: String, in text: String,
                      after anchor: String? = nil) throws -> String {
        let start: String.Index
        if let anchor {
            start = try XCTUnwrap(text.range(of: anchor), "anchor not found: \(anchor)").upperBound
        } else {
            start = text.startIndex
        }
        let signatureRange = try XCTUnwrap(text.range(of: signature, range: start..<text.endIndex),
                                           "signature not found: \(signature)")
        let open = try XCTUnwrap(text.range(of: "{", range: signatureRange.upperBound..<text.endIndex),
                                 "no body after \(signature)")
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        XCTFail("unbalanced braces after \(signature)")
        return ""
    }

    // MARK: - Tests

    /// The positive control. A scan that read no files, or looked in the wrong root, passes every
    /// absence assertion below while proving nothing; this makes that a red test instead.
    func testTheScanReachesTheSourcesItClaims() throws {
        let sources = try sources()

        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files to mean anything")
        XCTAssertNotNil(sources["OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Engines/RemoteEngine.swift"])
        XCTAssertNotNil(sources["OpenSuperWhisper/Utils/SourceCapture.swift"])
        // One file from the added package root, so a root that moved or was never scanned fails
        // here rather than reporting an absence it never looked for.
        XCTAssertNotNil(sources["LiquidGlass/Sources/LiquidGlass/GlassSurface.swift"],
                        "the LiquidGlass source root was not scanned")
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
    /// is worthless if `generate` builds its own copy of the request.
    ///
    /// The earlier version counted `request(for:` anywhere in the file, so a second call site
    /// could keep it green while `generate` bypassed the builder. This scopes to `generate`'s own
    /// body: it must call the builder, and it must not build or serialise a request itself.
    /// Mutation: inline the build in `generate` (a `URLRequest(` or `JSONSerialization` call) and
    /// both absence rows redden; drop the builder call and the first row reddens.
    func testGenerateUsesTheInspectedBuilder() throws {
        let path = "OpenSuperWhisperCore/Sources/OpenSuperWhisperCore/Utils/LLMCleanup/RemoteBackend.swift"
        let all = try sources()
        let text = try XCTUnwrap(all[path])
        let generate = try body(of: "func generate(", in: text)

        XCTAssertTrue(generate.contains("request(for:"),
                      "generate no longer calls request(for:system:): the cleanup privacy test inspects dead code")
        XCTAssertFalse(generate.contains("URLRequest("),
                       "generate builds its own request, so the inspected builder is not what it sends")
        XCTAssertFalse(generate.contains("JSONSerialization"),
                       "generate serialises its own body, so the inspected builder is not what it sends")
    }

    /// The secure-field predicate is tested on its own; nothing checked that the readers ask it.
    /// `SecureTextFields` names them — `SourceCapture` (what the transcriber is told),
    /// `TextAroundCaret` (how the dictation is fitted), `WatchedField` (what the user corrected),
    /// `FocusUtils.focusedTextMetrics` (the length and caret written to the diagnostic log) and
    /// `FocusReturn` (the length and selection kept so the caret can be put back) — so a reader
    /// that stopped calling it, or called it without negating the answer, would leave every
    /// predicate test green while reading a password box.
    ///
    /// Only the first feeds a model; they share the guard because a password box is not ours to
    /// read for any purpose, and the metrics and return readers are why: they write a fact about
    /// the field to a log, or keep it for the length of a transcription.
    ///
    /// Blind spot, stated: this covers the five files that are the readers today. A NEW reader
    /// that never calls the guard is not caught, because finding it would mean enumerating
    /// "Accessibility readers", a curated list with the same weakness as the network one above.
    func testEveryReaderAsksTheSecureFieldGuard() throws {
        let sources = try sources()
        let readers = [
            "OpenSuperWhisper/Utils/SourceCapture.swift",
            "OpenSuperWhisper/Utils/TextAroundCaret.swift",
            "OpenSuperWhisper/Utils/WatchedField.swift",
            "OpenSuperWhisper/Utils/FocusUtils.swift",
            "OpenSuperWhisper/Utils/FocusReturn.swift",
        ]

        for path in readers {
            let text = try XCTUnwrap(sources[path], "reader not found: \(path)")
            XCTAssertTrue(text.contains("!SecureTextFields.isSecure("),
                          "\(path) no longer refuses a secure field, or calls the guard without negating it")
        }
    }

    /// The guard must come before the read it guards — the behavioural half.
    ///
    /// A behavioural version that hands a reader a secure element cannot be built in a test
    /// process: no AX element can be given a subrole the test controls, and an untrusted reader
    /// returns nil for every element, so "a secure field yields nothing" would pass for the wrong
    /// reason. The discriminating change is moving a read above the guard, which this catches per
    /// site: the value, the length and the selection each have to sit after the subrole check in
    /// the function that performs them.
    ///
    /// Mutation: move `kAXValueAttribute` above the guard in `SourceCapture`, or either length or
    /// selection read above it in `TextAroundCaret`, `FocusUtils` or `FocusReturn`, and that
    /// site's row reddens. `WatchedField` is pinned at the other end: the field it builds may
    /// only be returned after the guard, and its private init is what keeps a new caller from
    /// skipping `focused(in:)`.
    func testEveryReaderChecksTheSubroleBeforeItReads() throws {
        let sources = try sources()
        let sites: [(path: String, anchor: String?, signature: String, reads: [String])] = [
            ("OpenSuperWhisper/Utils/SourceCapture.swift", nil,
             "static func focusedText(in element: AXUIElement) -> String?",
             ["kAXValueAttribute"]),
            ("OpenSuperWhisper/Utils/TextAroundCaret.swift", nil,
             "private static func read(_ element: AXUIElement, with ax: TimedAccessibility) -> TextAroundCaret?",
             ["kAXSelectedTextRangeAttribute", "kAXStringForRangeParameterizedAttribute",
              "kAXValueAttribute"]),
            ("OpenSuperWhisper/Utils/WatchedField.swift", nil,
             "static func focused(in pid: pid_t) -> WatchedField?",
             ["return field"]),
            ("OpenSuperWhisper/Utils/FocusUtils.swift", nil,
             "static func focusedTextMetrics() -> (length: Int?, caret: Int?)?",
             ["kAXNumberOfCharactersAttribute", "kAXSelectedTextRangeAttribute"]),
            ("OpenSuperWhisper/Utils/FocusReturn.swift", nil,
             "static func capture(_ app: NSRunningApplication) -> FocusTarget",
             ["kAXNumberOfCharactersAttribute", "kAXSelectedTextRangeAttribute"]),
            ("OpenSuperWhisper/Utils/FocusReturn.swift", "final class LiveFocusControl",
             "func field(_ target: FocusTarget) -> FieldSnapshot?",
             ["kAXNumberOfCharactersAttribute", "kAXSelectedTextRangeAttribute"]),
        ]

        for site in sites {
            let text = try XCTUnwrap(sources[site.path], "reader not found: \(site.path)")
            let function = try body(of: site.signature, in: text, after: site.anchor)
            let guardRange = try XCTUnwrap(function.range(of: "SecureTextFields.isSecure("),
                                           "\(site.path): no subrole check in \(site.signature)")
            for read in site.reads {
                let readRange = try XCTUnwrap(function.range(of: read),
                                              "\(site.path): read marker missing from \(site.signature): \(read)")
                XCTAssertLessThan(guardRange.lowerBound, readRange.lowerBound,
                                  "\(site.path): \(read) is read before the subrole check")
            }
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

    /// The other half of F2: `captureFocusedText` asks whether it may read before it reads, so a
    /// remote engine — or the switch turned off — returns without touching Accessibility at all.
    ///
    /// A behavioural version was proposed and would not discriminate here: call it with the
    /// engine set to remote and assert `focusedText == nil`. The full path also produces nil in a
    /// headless test process, because `SourceCapture.focusedText()` finds no frontmost app it is
    /// allowed to read (our own bundle is skipped, and an unprivileged process cannot read
    /// another app). Both branches would return nil and the test would be green for the wrong
    /// reason. The discriminating observable is the position of the guard relative to the read.
    func testTheGuardReturnsBeforeAnyAccessibilityRead() throws {
        let path = "OpenSuperWhisper/AppContextModelRules.swift"
        let text = try XCTUnwrap(try sources()[path])

        let method = try XCTUnwrap(text.range(of: "func captureFocusedText()"))
        let body = text[method.lowerBound...]
        let guardAt = try XCTUnwrap(body.range(of: "wantsFieldText("),
                                    "captureFocusedText no longer consults the gate")
        let firstRead = try XCTUnwrap(body.range(of: "SourceCapture.focusedText("),
                                      "captureFocusedText no longer reads the field")

        XCTAssertLessThan(guardAt.lowerBound, firstRead.lowerBound,
                          "the field is read before the gate says it may be — a secure or remote engine could be read")
    }

    /// F4, pinned where a behavioural row cannot always reach it: the menu path must not write
    /// the field text, and `update` must not grow a way to.
    ///
    /// `FieldContextGateTests.testTheMenuPathLeavesTheRecordedFieldTextAlone` drives the real
    /// `captureFrontmost(forRecording: false)`, but that method returns early when the frontmost
    /// app is not one it may read, and a headless process cannot choose one. This asserts the
    /// invariant on the source, so an assignment before or after that early return both redden.
    ///
    /// Mutation: add `focusedText = nil` in `captureFrontmost`, call `consumeFocusedText()` or
    /// `clearFocusedText()` there, or give `update` a field-text parameter and assignment.
    func testTheMenuPathCannotWriteTheFieldText() throws {
        let text = try XCTUnwrap(try sources()["OpenSuperWhisper/AppContextModelRules.swift"])

        let capture = try body(of: "func captureFrontmost(forRecording: Bool = true)", in: text)
        XCTAssertFalse(capture.contains("focusedText ="),
                       "captureFrontmost writes the field text: the menu path can erase a recording's field")
        XCTAssertFalse(capture.contains("consumeFocusedText("),
                       "captureFrontmost consumes the field text")
        XCTAssertFalse(capture.contains("clearFocusedText("),
                       "captureFrontmost clears the field text")

        let update = try body(of: "func update(appName:", in: text)
        XCTAssertFalse(update.contains("focusedText"),
                       "update writes the field text: every caller of it can erase or invent one")
    }
}
