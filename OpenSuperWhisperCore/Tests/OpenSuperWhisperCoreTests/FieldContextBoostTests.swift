import XCTest
@testable import OpenSuperWhisperCore

/// The Parakeet boost one clip at a time (#89).
///
/// `activeBoostTerms` is the composition the engine hands to the rescorer, and the booster caches
/// its session on that exact list. So the property worth pinning is per-clip: what clip B is
/// biased toward must be B's field, not whatever the previous clip was started in.
///
/// This is the seam the review asked to be widened from `private`. It covers the composition; it
/// does NOT exercise `boostingSession`'s cache, which is still private. The cache is keyed on the
/// merged list, so two clips with different field terms produce different keys by construction —
/// but if that keying ever changed, this test would stay green and only a cache-level test would
/// catch it. Stated rather than implied.
final class FieldContextBoostTests: CoreTestCase {

    private func engine() -> FluidAudioEngine { FluidAudioEngine() }

    /// Two clips, two fields. Mutation: drop `fieldTerms` from the merged list, or cache the
    /// first clip's list and return it for the second, and the second assertion reddens.
    func testOneClipsFieldTermsDoNotReachTheNextClip() {
        let settings = Fixtures.pinnedSettings()
        let engine = engine()

        let first = engine.activeBoostTerms(settings, fieldTerms: ["Cherith", "Nyiragongo"])
        let second = engine.activeBoostTerms(settings, fieldTerms: ["Sintra"])

        XCTAssertEqual(first, ["Cherith", "Nyiragongo"])
        XCTAssertEqual(second, ["Sintra"], "clip B reused clip A's field terms")
    }

    /// The cap bounds the field's contribution only. A user with a large dictionary sees no change
    /// — the plan's reason for not capping the merged list — and the field takes whatever room is
    /// left. Mutation: drop the `prefix` and the count assertion reddens.
    func testTheCapAppliesToTheFieldsContributionOnly() {
        let settings = Fixtures.pinnedSettings()
        let engine = engine()
        let many = (0..<60).map { "Term\($0)" }

        let boosted = engine.activeBoostTerms(settings, fieldTerms: many)

        XCTAssertEqual(boosted.count, FluidAudioEngine.mergedTermLimit)
        XCTAssertEqual(boosted, Array(many.prefix(FluidAudioEngine.mergedTermLimit)))
    }
}
