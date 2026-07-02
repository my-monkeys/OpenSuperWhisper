import XCTest
@testable import OpenSuperWhisper

/// `SourceCapture.host(of:)` extracts a bare hostname from a browser URL for the
/// per-site model rules and the history "source" line — stripping a leading
/// `www.` so a rule keyed on `github.com` still matches `www.github.com`. This
/// guards the parsing edge cases (nil / empty / non-URL / no host) so a malformed
/// URL never crashes or yields a bogus site key.
final class SourceCaptureHostTests: XCTestCase {

    func testExtractsHost() {
        XCTAssertEqual(SourceCapture.host(of: "https://docs.google.com/document/d/abc"), "docs.google.com")
        XCTAssertEqual(SourceCapture.host(of: "http://litellm.docker.lan:4000/v1"), "litellm.docker.lan")
    }

    func testStripsLeadingWWW() {
        XCTAssertEqual(SourceCapture.host(of: "https://www.github.com/user/repo"), "github.com")
    }

    func testDoesNotStripWWWWhenPartOfLabel() {
        // "www2" is not the "www." prefix — leave it intact.
        XCTAssertEqual(SourceCapture.host(of: "https://www2.example.com"), "www2.example.com")
    }

    func testReturnsNilForNilEmptyOrNonURL() {
        XCTAssertNil(SourceCapture.host(of: nil))
        XCTAssertNil(SourceCapture.host(of: ""))
        XCTAssertNil(SourceCapture.host(of: "justtext"))
        XCTAssertNil(SourceCapture.host(of: "/relative/path"))
    }
}
