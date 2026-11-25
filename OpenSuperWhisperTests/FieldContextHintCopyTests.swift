import Foundation
import XCTest

/// The field-context copy, bound to the shipped literals (#89).
///
/// The layout test renders the arms and the localization script proves every catalog entry has
/// its seven translations. Neither can see which arm a mode is wired to: swapping the `.terms`
/// and `.none` sentences, or editing one, ships green there. This reads the two view sources and
/// binds each state to its exact sentence.
///
/// It is a source assertion, not a render: SwiftUI draws some text with no view to walk, and a
/// headless render cannot be asked which string it drew without a fragile view-tree search. The
/// literals below are the shipped ones; changing the copy means changing this file with it.
final class FieldContextHintCopyTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenSuperWhisperTests
            .deletingLastPathComponent()  // repo root
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of the computed property whose declaration contains `signature`, braces matched
    /// from its opening brace. These two bodies carry no brace inside a string literal.
    private func body(of signature: String, in text: String) throws -> String {
        let signatureRange = try XCTUnwrap(text.range(of: signature),
                                           "declaration not found: \(signature)")
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

    private func caseBody(_ mode: String, in switchBody: String) throws -> String {
        let start = try XCTUnwrap(switchBody.range(of: "case \(mode):"),
                                  "no \(mode) arm in the hint switch")
        let rest = switchBody[start.upperBound...]
        let end = rest.range(of: "case .")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// One sentence per engine mode, exactly as shipped. Mutation: swap the `.terms` and `.none`
    /// bodies and both rows redden; edit any sentence and its row reddens.
    func testTheRecognitionHintMatchesTheShippedCopyPerMode() throws {
        let text = try source("OpenSuperWhisper/Settings/Rubrics/TextAndAI/TextAIRecognitionGroup.swift")
        let hint = try body(of: "private var fieldContextHint: LocalizedStringKey", in: text)

        let expected: [(mode: String, literal: String)] = [
            (".prose", "Reads the focused field to recognise names better. The field text is never sent as context, but a recognised word can end up in your transcript, which goes to your AI engine when cleanup runs."),
            (".terms", "Reads the focused field and gives Parakeet a term list from it, not a sentence. The field text is never sent as context, but a word that sounds close to a listed term can be rewritten into your transcript, which goes to your AI engine when cleanup runs."),
            (".none", "This engine takes no hint about what is coming, so the field is not read."),
            (".remoteExcluded", "Never: this text would be sent to your server, so the field is not read."),
        ]
        for row in expected {
            let arm = try caseBody(row.mode, in: hint)
            XCTAssertTrue(arm.contains(row.literal),
                          "\(row.mode) does not return the shipped sentence")
        }
    }

    /// The Privacy hint's three states: off (the default case above), on, and on-but-unused. The
    /// capability check must come first and return the "not read" sentence, and only then may the
    /// plain on sentence be returned.
    /// Mutation: drop the `canUseFieldContext` guard and the first order assertion reddens; swap
    /// the two on-sentences and the second reddens.
    func testThePrivacyHintKeepsItsThreeStates() throws {
        let text = try source("OpenSuperWhisper/Settings/Rubrics/PrivacyRubric.swift")
        let hint = try body(of: "private var modelContextHint: LocalizedStringKey", in: text)

        let capability = try XCTUnwrap(hint.range(of: "guard viewModel.canUseFieldContext"))
        let unused = try XCTUnwrap(hint.range(of: "On, but this engine does not use it: the field is not read."))
        let on = try XCTUnwrap(hint.range(of: "On: the text before your cursor is read to help the model recognise names. It is never sent as context, but a recognised word can end up in your transcript, which goes to your AI engine when cleanup runs."))
        XCTAssertLessThan(capability.lowerBound, unused.lowerBound,
                          "the on-but-unused state is not behind the capability check")
        XCTAssertLessThan(unused.lowerBound, on.lowerBound,
                          "the capability check does not return before the plain on-state")
    }
}
