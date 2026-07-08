import XCTest
@testable import OpenSuperWhisper

/// Covers the pure parsing behind voice commands: wake-word detection, verb/app parsing, the
/// dictation-vs-command classification, the trailing submit command, and the fuzzy app matcher.
/// Execution (NSWorkspace side effects) is not unit-tested.
final class VoiceCommandRouterTests: XCTestCase {

    // MARK: - stripWakeWord

    func testStripWakeWordBasic() {
        XCTAssertEqual(VoiceCommandRouter.stripWakeWord("whisper open slack", trigger: "whisper"), "open slack")
    }

    func testStripWakeWordCaseAndCommaInsensitive() {
        XCTAssertEqual(VoiceCommandRouter.stripWakeWord("Whisper, open Slack", trigger: "whisper"), "open Slack")
    }

    func testStripWakeWordRequiresWholeWord() {
        // "whispering" must not trigger on the "whisper" prefix.
        XCTAssertNil(VoiceCommandRouter.stripWakeWord("whispering quietly to him", trigger: "whisper"))
    }

    func testStripWakeWordAbsent() {
        XCTAssertNil(VoiceCommandRouter.stripWakeWord("open slack", trigger: "whisper"))
    }

    func testStripWakeWordAloneIsNotACommand() {
        XCTAssertNil(VoiceCommandRouter.stripWakeWord("whisper", trigger: "whisper"))
    }

    // MARK: - parseAppCommand

    func testParseOpen() {
        XCTAssertEqual(VoiceCommandRouter.parseAppCommand("open slack"),
                       .init(action: .activate, query: "slack"))
    }

    func testParseSwitchToMultiWordVerb() {
        XCTAssertEqual(VoiceCommandRouter.parseAppCommand("switch to visual studio code"),
                       .init(action: .activate, query: "visual studio code"))
    }

    func testParseQuit() {
        XCTAssertEqual(VoiceCommandRouter.parseAppCommand("quit spotify"),
                       .init(action: .quit, query: "spotify"))
    }

    func testParseUnknownVerb() {
        XCTAssertNil(VoiceCommandRouter.parseAppCommand("hello there"))
    }

    func testParseVerbWithoutAppIsNil() {
        XCTAssertNil(VoiceCommandRouter.parseAppCommand("open"))
    }

    func testParseStripsTrailingPunctuationFromSpeech() {
        // Whisper appends a period to short utterances ("open safari." → query "safari").
        XCTAssertEqual(VoiceCommandRouter.parseAppCommand("open safari."),
                       .init(action: .activate, query: "safari"))
        XCTAssertEqual(VoiceCommandRouter.parseAppCommand("switch to visual studio code."),
                       .init(action: .activate, query: "visual studio code"))
    }

    // MARK: - classify

    func testClassifyDictationWhenNoTrigger() {
        XCTAssertEqual(VoiceCommandRouter.classify("open slack", trigger: "whisper"), .dictation)
    }

    func testClassifyCommand() {
        XCTAssertEqual(VoiceCommandRouter.classify("whisper open slack", trigger: "whisper"),
                       .command(.init(action: .activate, query: "slack")))
    }

    func testClassifyUnrecognizedWhenTriggerButNoVerb() {
        XCTAssertEqual(VoiceCommandRouter.classify("whisper hello there", trigger: "whisper"), .unrecognized)
    }

    // MARK: - parseSubmitCommand

    func testSubmitCommandDetected() {
        let result = VoiceCommandRouter.parseSubmitCommand("send the message press enter")
        XCTAssertEqual(result.text, "send the message")
        XCTAssertTrue(result.submit)
    }

    func testSubmitCommandAbsent() {
        let result = VoiceCommandRouter.parseSubmitCommand("just some dictation")
        XCTAssertEqual(result.text, "just some dictation")
        XCTAssertFalse(result.submit)
    }

    // MARK: - InstalledApps.bestMatch

    private let apps = [
        InstalledApp(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app")),
        InstalledApp(bundleIdentifier: "com.tinyspeck.slack.helper", name: "Slack Helper", url: URL(fileURLWithPath: "/x/Slack Helper.app")),
        InstalledApp(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code", url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")),
    ]

    func testBestMatchExactBeatsContaining() {
        // "slack" must pick "Slack", not "Slack Helper".
        XCTAssertEqual(InstalledApps.bestMatch(forSpokenName: "slack", in: apps)?.name, "Slack")
    }

    func testBestMatchContains() {
        XCTAssertEqual(InstalledApps.bestMatch(forSpokenName: "visual studio", in: apps)?.name, "Visual Studio Code")
    }

    func testBestMatchNone() {
        XCTAssertNil(InstalledApps.bestMatch(forSpokenName: "photoshop", in: apps))
    }

    func testBestMatchIgnoresTrailingPunctuation() {
        XCTAssertEqual(InstalledApps.bestMatch(forSpokenName: "slack.", in: apps)?.name, "Slack")
    }
}
