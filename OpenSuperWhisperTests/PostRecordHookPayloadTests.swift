//
//  PostRecordHookPayloadTests.swift
//  OpenSuperWhisperTests
//
//  Covers the data the post-record hook hands to a user's script. A hook consumer's script
//  breaks silently if a key is renamed or dropped, so the shape is pinned here rather than
//  only exercised by launching a process.
//

import XCTest
@testable import OpenSuperWhisper

final class PostRecordHookPayloadTests: XCTestCase {

    private let timestamp = Date(timeIntervalSince1970: 1_789_236_556)

    private func payload(text: String = "We should build the harness first.",
                         rawText: String = "um we should build the harness first",
                         bundleID: String? = "com.tinyspeck.slackmacgap",
                         audioPath: String? = "/tmp/clip.wav") -> PostRecordHook.Payload {
        PostRecordHook.Payload(text: text, rawText: rawText, bundleID: bundleID,
                               audioPath: audioPath, timestamp: timestamp, duration: 15.38)
    }

    /// The four fields scripts already depend on keep their names and their meaning.
    func testExistingFieldsAreUnchanged() {
        let env = payload().environment

        XCTAssertEqual(env["OSW_TEXT"], "We should build the harness first.")
        XCTAssertEqual(env["OSW_AUDIO_PATH"], "/tmp/clip.wav")
        XCTAssertEqual(env["OSW_TIMESTAMP"], ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(env["OSW_DURATION"], "15.38")
    }

    func testRawTextIsTheEngineOutputBeforeCleanup() {
        XCTAssertEqual(payload().environment["OSW_RAW_TEXT"],
                       "um we should build the harness first")
    }

    func testBundleIDIsTheAppDictatedInto() {
        XCTAssertEqual(payload().environment["OSW_APP_BUNDLE_ID"],
                       "com.tinyspeck.slackmacgap")
    }

    /// A missing bundle id is an empty variable, matching how `OSW_AUDIO_PATH` already behaves
    /// — a script reads "" rather than the variable vanishing from the environment.
    func testAMissingBundleIDIsAnEmptyString() {
        let env = payload(bundleID: nil, audioPath: nil).environment

        XCTAssertEqual(env["OSW_APP_BUNDLE_ID"], "")
        XCTAssertEqual(env["OSW_AUDIO_PATH"], "")
    }

    /// With no dictionary rules and no LLM cleanup the two texts are the same, and a script
    /// can tell "nothing changed it" from "it was rewritten" by comparing them.
    func testRawTextEqualsTextWhenNothingRewroteIt() {
        let same = payload(text: "test paste loop 1 2 3", rawText: "test paste loop 1 2 3")

        XCTAssertEqual(same.environment["OSW_TEXT"], same.environment["OSW_RAW_TEXT"])
    }

    func testJSONCarriesTheSameSixFields() throws {
        let data = try JSONSerialization.data(withJSONObject: payload().json)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["text"] as? String, "We should build the harness first.")
        XCTAssertEqual(object["rawText"] as? String, "um we should build the harness first")
        XCTAssertEqual(object["bundleID"] as? String, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(object["audioPath"] as? String, "/tmp/clip.wav")
        XCTAssertEqual(object["timestamp"] as? String,
                       ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(object["duration"] as? Double, 15.38)
        XCTAssertEqual(object.count, 6)
    }

    /// The JSON is what a script parses, so it must survive serialization with a nil bundle id.
    func testJSONSerializesWithNoBundleIDAndNoAudio() throws {
        let data = try JSONSerialization.data(
            withJSONObject: payload(bundleID: nil, audioPath: nil).json)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["bundleID"] as? String, "")
        XCTAssertEqual(object["audioPath"] as? String, "")
    }
}
