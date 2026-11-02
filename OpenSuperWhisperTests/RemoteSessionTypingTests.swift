import Carbon
import XCTest

@testable import OpenSuperWhisper

/// Which keys a remote session receives for a dictation (#255). Layouts are read from the
/// installed list rather than selected, so the user's input source is never switched; a layout
/// missing from this machine skips its test.
final class RemoteSessionTypingTests: XCTestCase {

    private func map(_ id: String) throws -> KeystrokeMap {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
                as? [TISInputSource],
              let source = sources.first,
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { throw XCTSkip("\(id) is not installed on this machine") }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        return try XCTUnwrap(KeystrokeMap(layoutData: data, keyboardType: UInt32(LMGetKbdType())))
    }

    func testScreenSharingIsARemoteSession() {
        XCTAssertTrue(RemoteSession.isRemoteSession("com.apple.ScreenSharing"))
        XCTAssertFalse(RemoteSession.isRemoteSession("com.apple.Terminal"))
        XCTAssertFalse(RemoteSession.isRemoteSession(nil))
    }

    func testUSLetterNeedsNoModifier() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan("a").strokes, [KeyStroke(keyCode: 0x00)])
    }

    func testCapitalPressesShiftAroundTheLetter() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan("H").strokes,
                       [KeyStroke(keyCode: 0x04, shift: true)])
    }

    /// The key of the reported "VV": a V is the V key, never a ⌘ shortcut.
    func testVIsTypedAsALetter() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan("v").strokes, [KeyStroke(keyCode: 0x09)])
    }

    func testUSReachesAnAccentThroughItsDeadKey() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan("é").strokes,
                       [KeyStroke(keyCode: 0x0E, option: true), KeyStroke(keyCode: 0x0E)])
    }

    /// AZERTY has an é key, and its A is where QWERTY has Q.
    func testAZERTYUsesItsOwnKeys() throws {
        let azerty = try map("com.apple.keylayout.French")
        XCTAssertEqual(azerty.plan("é").strokes, [KeyStroke(keyCode: 0x13)])
        XCTAssertEqual(azerty.plan("a").strokes, [KeyStroke(keyCode: 0x0C)])
    }

    /// A period from the keypad is an arrow key on a Windows machine with Num Lock off.
    func testPeriodComesFromTheMainRows() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan(".").strokes, [KeyStroke(keyCode: 0x2F)])
    }

    func testLineBreakPressesReturn() throws {
        XCTAssertEqual(try map("com.apple.keylayout.US").plan("\n").strokes,
                       [KeyStroke(keyCode: KeystrokeMap.returnKeyCode)])
    }

    func testANarrowNoBreakSpaceIsTypedAsASpace() throws {
        let us = try map("com.apple.keylayout.US")
        XCTAssertEqual(us.plan("\u{202F}").strokes, us.plan(" ").strokes)
    }

    func testAnEmojiIsSkippedAndTheRestStillTyped() throws {
        let plan = try map("com.apple.keylayout.US").plan("ok 👍")
        XCTAssertEqual(plan.skipped, ["👍"])
        XCTAssertEqual(plan.strokes.count, 3)
    }
}
