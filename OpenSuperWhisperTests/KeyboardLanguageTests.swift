//
//  KeyboardLanguageTests.swift
//  OpenSuperWhisperTests
//
//  Picking the transcription language from the keyboard layout (#120). Input sources speak
//  BCP 47 and the engines each speak their own code list, so the interesting part is what
//  happens when the two do not line up.
//

import XCTest
@testable import OpenSuperWhisper

final class KeyboardLanguageTests: XCTestCase {

    private let whisperish = ["auto", "en", "fr", "de", "pt", "zh", "ja"]

    func testAPlainTagIsUsedAsIs() {
        XCTAssertEqual(KeyboardLanguage.resolve(declared: ["fr"], supported: whisperish), "fr")
    }

    /// "French - PC" and "French" both declare `fr`, which is the easy case. A regional tag is
    /// the one that matters: Brazilian Portuguese must reach Portuguese rather than nothing.
    func testARegionalTagFallsBackToItsPrimarySubtag() {
        XCTAssertEqual(KeyboardLanguage.resolve(declared: ["pt-BR"], supported: whisperish), "pt")
        XCTAssertEqual(KeyboardLanguage.resolve(declared: ["zh-Hans"], supported: whisperish), "zh")
    }

    func testCaseIsIgnored() {
        XCTAssertEqual(KeyboardLanguage.resolve(declared: ["FR"], supported: whisperish), "fr")
    }

    /// A layout declares every language it can type, not a preference order. Measured on macOS
    /// 27: ABC-AZERTY declares ninety-five, `fr` first and then Afrikaans, Cebuano, Corsican and
    /// most of the Latin script. Only the first counts, or a French speaker on an engine without
    /// French would be transcribed as Danish because Danish happened to be further down.
    func testOnlyTheLayoutsOwnLanguageCounts() {
        let azerty = ["fr", "af", "ceb", "co", "da", "de", "en"]

        XCTAssertEqual(KeyboardLanguage.resolve(declared: azerty, supported: whisperish), "fr")
        XCTAssertNil(KeyboardLanguage.resolve(declared: azerty, supported: ["auto", "da", "de"]))
    }

    /// An engine with a short list must not be handed a language it would reject. Parakeet v2
    /// is English only, so a French layout resolves to nothing here and the caller falls back.
    func testALayoutTheEngineCannotTranscribeResolvesToNothing() {
        XCTAssertNil(KeyboardLanguage.resolve(declared: ["fr"], supported: ["en"]))
    }

    func testALayoutThatDeclaresNothingResolvesToNothing() {
        XCTAssertNil(KeyboardLanguage.resolve(declared: [], supported: whisperish))
    }

    /// Auto-detect rather than English: a layout with no usable language is typically an Asian
    /// input method, and guessing from the audio beats assuming the user speaks English.
    func testAnUnresolvableLayoutFallsBackToAutoDetect() {
        XCTAssertEqual(KeyboardLanguage.language(for: KeyboardLanguage.selectionCode, resolved: nil),
                       "auto")
    }

    func testAResolvedLayoutIsWhatTheEngineIsTold() {
        XCTAssertEqual(KeyboardLanguage.language(for: KeyboardLanguage.selectionCode, resolved: "de"),
                       "de")
    }

    /// A user who picked a fixed language keeps it, whatever the layout says. This is the path
    /// every existing install takes, so it has to be untouched.
    func testAFixedLanguageIgnoresTheLayoutEntirely() {
        XCTAssertEqual(KeyboardLanguage.language(for: "cs", resolved: "fr"), "cs")
        XCTAssertEqual(KeyboardLanguage.language(for: "auto", resolved: "fr"), "auto")
    }

    /// The pseudo-code must never reach an engine: it names a way of choosing a language, not
    /// a language, and `whisper_lang_id` would reject it.
    func testThePseudoCodeIsNotAWhisperLanguage() {
        XCTAssertFalse(LanguageUtil.availableLanguages.contains(KeyboardLanguage.selectionCode))
    }
}
