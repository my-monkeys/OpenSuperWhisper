//
//  DictionaryLineBreakTests.swift
//  OpenSuperWhisperTests
//
//  Saying "new paragraph" and getting one. A replacement that is itself whitespace cannot be
//  typed literally, because the field is trimmed to spot a row someone has half filled in, so
//  the escape is what makes a spoken line break expressible at all (#121).
//

import XCTest
@testable import OpenSuperWhisper

final class DictionaryLineBreakTests: XCTestCase {

    private func rule(_ trigger: String, _ replacement: String,
                      regex: Bool = false) -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: trigger, replacement: replacement, isRegex: regex)
    }

    // MARK: - the escape itself

    func testBackslashNBecomesANewline() {
        XCTAssertEqual(CustomDictionary.unescaped("a\\nb"), "a\nb")
    }

    func testBackslashTBecomesATab() {
        XCTAssertEqual(CustomDictionary.unescaped("a\\tb"), "a\tb")
    }

    /// Someone who wants a literal backslash says so, and gets one rather than an escape.
    func testADoubledBackslashIsOneBackslash() {
        XCTAssertEqual(CustomDictionary.unescaped("C:\\\\path"), "C:\\path")
    }

    /// An escape nobody defined is left exactly as typed rather than quietly eaten.
    func testAnUnknownEscapeIsLeftAlone() {
        XCTAssertEqual(CustomDictionary.unescaped("\\q"), "\\q")
    }

    func testATrailingBackslashSurvives() {
        XCTAssertEqual(CustomDictionary.unescaped("end\\"), "end\\")
    }

    func testTextWithoutEscapesIsUntouched() {
        XCTAssertEqual(CustomDictionary.unescaped("My-Monkey"), "My-Monkey")
    }

    // MARK: - what it does to a dictation

    func testSpokenNewLineBecomesALineBreak() {
        let out = CustomDictionary.apply("first thought new line second thought",
                                         entries: [rule("new line", "\\n")])

        XCTAssertEqual(out, "first thought\nsecond thought")
    }

    func testSpokenNewParagraphBecomesABlankLine() {
        let out = CustomDictionary.apply("the end new paragraph and then",
                                         entries: [rule("new paragraph", "\\n\\n")])

        XCTAssertEqual(out, "the end\n\nand then")
    }

    /// The rule is the user's, so the false positive is theirs to decide on. What matters here
    /// is that an ordinary sentence containing the words is not silently rewritten by something
    /// they did not ask for: nothing happens until they write the rule.
    func testNothingHappensWithoutARule() {
        let out = CustomDictionary.apply("he moved to the new line of work", entries: [])

        XCTAssertEqual(out, "he moved to the new line of work")
    }

    /// A regex rule's replacement is an NSRegularExpression template, where a backslash already
    /// escapes the next character. Rewriting those would change what existing rules do.
    func testARegexRuleKeepsItsTemplateSemantics() {
        let out = CustomDictionary.apply("say hello",
                                         entries: [rule("(hello)", "[$1]", regex: true)])

        XCTAssertEqual(out, "say [hello]")
    }
}
