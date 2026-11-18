import XCTest
@testable import OpenSuperWhisperCore

/// The silence a dictation gets on both sides before Parakeet hears it, so a take cut on the
/// key press or release does not lose its first or last word.
final class ClipEdgePaddingTests: CoreTestCase {
    func testTheClipIsSurroundedBySilenceAndKeptIntact() {
        let clip: [Float] = [0.5, -0.25, 0.125]
        let padded = ClipEdgePadding.padded(clip)

        let lead = Int(ClipEdgePadding.leadingSeconds * Double(ClipEdgePadding.sampleRate))
        let tail = Int(ClipEdgePadding.trailingSeconds * Double(ClipEdgePadding.sampleRate))
        XCTAssertEqual(padded.count, lead + clip.count + tail)
        XCTAssertTrue(padded.prefix(lead).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(padded[lead..<(lead + clip.count)]), clip)
        XCTAssertTrue(padded.suffix(tail).allSatisfy { $0 == 0 })
    }

    func testDictationsArePaddedButMeetingLengthFilesAreNot() {
        XCTAssertTrue(ClipEdgePadding.fits(durationSeconds: 4))
        XCTAssertTrue(ClipEdgePadding.fits(durationSeconds: ClipEdgePadding.maximumClipSeconds))
        XCTAssertFalse(ClipEdgePadding.fits(durationSeconds: ClipEdgePadding.maximumClipSeconds + 1))
    }
}
