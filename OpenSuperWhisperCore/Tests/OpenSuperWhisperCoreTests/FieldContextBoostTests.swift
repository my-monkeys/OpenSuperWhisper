import XCTest
@testable import OpenSuperWhisperCore

/// The Parakeet boost one clip at a time (#89), and the floors its terms carry (#307).
///
/// `boostPlan` is the composition the engine hands to the rescorer, and the booster caches its
/// session on that exact plan. So the property worth pinning is per-clip: what clip B is biased
/// toward must be B's field, not whatever the previous clip was started in.
///
/// This is the seam the review asked to be widened from `private`. It covers the composition and
/// the per-term floors; it does NOT exercise `boostingSession`'s cache, which is still private.
/// The cache is keyed on the whole plan (texts plus provenance), so two clips with different
/// field terms produce different keys by construction — but if that keying ever changed, this test
/// would stay green and only a cache-level test would catch it. Stated rather than implied.
final class FieldContextBoostTests: CoreTestCase {

    private func engine() -> FluidAudioEngine { FluidAudioEngine() }

    /// The floor each term in the plan carries, encoded as if every term tokenises.
    private func floors(_ plan: RecognitionBoost.Plan,
                        encode: (String) -> [Int] = { [$0.count] }) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: FluidAudioEngine.vocabularyTerms(for: plan, encode: encode)
            .map { ($0.text, $0.minSimilarity) })
    }

    /// A dictionary whose entries steer recognition, as the engine reads it from preferences.
    private func pinDictionary(_ count: Int) {
        let prefs = CoreTestEnvironment.preferences
        prefs.customDictionaryEntries = (0..<count).map {
            CustomDictionaryEntry(original: "spoken \($0)", replacement: "Term\($0)")
        }
        prefs.customDictionaryEnabled = true
    }

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

    // MARK: - Per-term floors (#307)
    //
    // FluidAudio is pinned at 0.18.3 (revision c8b41f98eae668794dd0083bbe028fe7e6585051, the
    // revision in the project's Package.resolved). The dependency symbols named below are read at
    // that pin; citations are by symbol, not by line, because a line number belongs to one
    // revision.
    //
    // The three effective bands are 0.52 up to 10 terms, 0.55 from 11 to 100, and 0.60 above 100
    // (`ContextBiasingConstants.rescorerConfig(forVocabSize:)` raised to the context's default).

    /// A dictionary keeps the floor its own list size gives it, whichever band it is in.
    /// Mutation: look the band up from a constant (or from the merged list's size) and the 11-
    /// and 101-term rows redden. Carrying no per-term floor at all is invisible here — with no
    /// field terms the merged list *is* the base list, so both floors coincide; that mutation is
    /// killed by `testFieldTermsCarryTheStricterFloor` and
    /// `testTheDictionariesFloorDoesNotMoveWhenFieldTermsJoin`.
    func testBaseFloorsAreTheBandsOfTheDictionariesOwnSize() {
        let bands: [(count: Int, floor: Float)] = [(5, 0.52), (11, 0.55), (101, 0.60)]
        for band in bands {
            pinDictionary(band.count)
            let plan = engine().boostPlan(Fixtures.pinnedSettings(), fieldTerms: [])
            XCTAssertEqual(Set(floors(plan).values), Set([band.floor]),
                           "\(band.count)-term dictionary")
        }
    }

    /// Field terms are held above every band floor, so a common word close to a name from the
    /// field is not rewritten (#307). Mutation: drop the per-term floor and they fall back to the
    /// merged list's band.
    func testFieldTermsCarryTheStricterFloor() {
        pinDictionary(5)
        let plan = engine().boostPlan(Fixtures.pinnedSettings(),
                                      fieldTerms: ["Cherith", "Nyiragongo"])
        let all = floors(plan)

        XCTAssertEqual(all["Cherith"], FluidAudioEngine.fieldTermMinSimilarity)
        XCTAssertEqual(all["Nyiragongo"], 0.75)
        XCTAssertEqual(all["Term0"], 0.52)
    }

    /// Field terms push the merged count past the small band, but the dictionary's own terms must
    /// not move: a user who changed nothing must not hear different replacements because a field
    /// was focused. Mutation: remove the per-term base floor and `Term0` reads 0.55 here.
    func testTheDictionariesFloorDoesNotMoveWhenFieldTermsJoin() {
        pinDictionary(5)
        let engine = engine()
        let settings = Fixtures.pinnedSettings()
        let alone = floors(engine.boostPlan(settings, fieldTerms: []))
        let withField = floors(engine.boostPlan(settings,
                                                fieldTerms: (0..<10).map { "Field\($0)" }))

        XCTAssertEqual(withField.count, 15, "the field should have contributed its ten terms")
        for (term, floor) in alone {
            XCTAssertEqual(withField[term], floor, "field terms moved \(term)'s floor")
        }
    }

    /// A dictionary at or past the merged limit still gets field terms; the old
    /// `max(0, 50 - base)` made the toggle a no-op (#126). No base term is dropped.
    func testAFiftyPlusTermDictionaryStillLeavesFieldTermsARoom() {
        pinDictionary(60)
        let field = (0..<10).map { "Field\($0)" }
        let plan = engine().boostPlan(Fixtures.pinnedSettings(), fieldTerms: field)

        XCTAssertEqual(plan.terms.count, 65)
        XCTAssertEqual(Array(plan.terms.prefix(60)), (0..<60).map { "Term\($0)" })
        XCTAssertEqual(Array(plan.terms.suffix(5)), Array(field.prefix(5)))
        XCTAssertEqual(plan.fieldForms, Set(field.prefix(5).map { $0.lowercased() }))
    }

    /// A term the tokenizer cannot encode is dropped, as the session's own tokenisation drops it
    /// (`CustomVocabularyContext.tokenizingMissingCtcTokens`), and the band counts the survivors —
    /// the grain `VocabularyBoostingSession.init` uses for its own band.
    /// Mutation: count before the drop and this 11-term dictionary reads 0.55 instead of 0.52.
    func testAnUnencodableTermIsDroppedAndTheBandCountsSurvivors() {
        pinDictionary(11)
        let plan = engine().boostPlan(Fixtures.pinnedSettings(), fieldTerms: [])
        let terms = FluidAudioEngine.vocabularyTerms(for: plan) { text in
            text == "Term3" ? [] : [text.count]
        }

        XCTAssertEqual(terms.count, 10)
        XCTAssertFalse(terms.contains { $0.text == "Term3" })
        XCTAssertEqual(Set(terms.map(\.minSimilarity)), Set([0.52]))
        XCTAssertTrue(terms.allSatisfy { !$0.ctcTokenIds.isEmpty },
                      "a term without CTC ids makes the session parse tokenizer.json again")
    }

    /// The cache key distinguishes the two sources even when the texts agree: a dictionary
    /// "Priya" and a field "Priya" merge to ["Priya"], and only the field copy is held to 0.75.
    /// Mutation: key the session on the merged texts and either clip gets the other's floor.
    func testTheSameTextFromTheDictionaryAndTheFieldIsNotTheSamePlan() {
        let fromDictionary = RecognitionBoost.plan(dictionary: ["Priya"], snippets: [], field: [])
        let fromField = RecognitionBoost.plan(dictionary: [], snippets: [], field: ["Priya"])

        XCTAssertEqual(fromDictionary.terms, fromField.terms)
        XCTAssertNotEqual(fromDictionary, fromField)
        XCTAssertEqual(floors(fromDictionary)["Priya"], 0.52)
        XCTAssertEqual(floors(fromField)["Priya"], 0.75)
    }

    /// The merge order and the cross-list dedupe are unchanged, and a field spelling the
    /// dictionary already supplies is dictionary evidence, not field evidence.
    func testADeduplicatedFieldTermIsNotFieldEvidence() {
        let plan = RecognitionBoost.plan(dictionary: ["GitHub"], snippets: ["github"],
                                         field: ["GitHub", "Nyiragongo"])

        XCTAssertEqual(plan.terms, ["GitHub", "Nyiragongo"])
        XCTAssertEqual(plan.fieldForms, Set(["nyiragongo"]))
    }

    // MARK: - Session cache and tokenizer directory

    /// The cache's key is the whole plan. The same plan reuses one session and counts no new
    /// build; the same texts with different provenance does not reuse it; and the slot holds one
    /// plan, not two. Mutation: compare `plan.terms` in `cached(for:)` and the field row returns
    /// the dictionary's session instead of nil; remove the increment from `store` and the
    /// build-count rows redden; keep a second slot and the eviction row reddens.
    func testTheBoostSessionCacheKeysOnProvenanceNotTexts() {
        var cache = FluidAudioEngine.BoostSessionCache<Int>()
        let fromDictionary = RecognitionBoost.plan(dictionary: ["Priya"], snippets: [], field: [])
        let fromField = RecognitionBoost.plan(dictionary: [], snippets: [], field: ["Priya"])
        XCTAssertEqual(fromDictionary.terms, fromField.terms, "the two plans must share their texts")

        XCTAssertNil(cache.cached(for: fromDictionary))
        cache.store(1, for: fromDictionary)
        XCTAssertEqual(cache.cached(for: fromDictionary), 1)
        XCTAssertEqual(cache.builds, 1, "a cache hit must not count as a build")

        XCTAssertNil(cache.cached(for: fromField),
                     "a texts-only key would serve the dictionary's session here")
        cache.store(2, for: fromField)
        XCTAssertEqual(cache.cached(for: fromField), 2)
        XCTAssertEqual(cache.builds, 2)
        XCTAssertNil(cache.cached(for: fromDictionary),
                     "the cache holds one plan; a second slot would still serve the old session")
    }

    /// The tokenizer must be loaded from the folder the session will use: the models' own folder
    /// when they carry one, otherwise the default cache. Mutation: drop the models-directory
    /// branch and the custom row returns the fallback. A custom-directory `CtcModels` cannot be
    /// constructed in a unit test — its public init needs `MLModel` instances and `loadDirect`
    /// needs CoreML model files — so the end-to-end case is covered by this precedence, not by
    /// building a model.
    func testTheTokenizerDirectoryFollowsTheModelsOwnFolder() {
        let fallback = URL(fileURLWithPath: "/tmp/fluidaudio-default-tokenizer")
        let custom = URL(fileURLWithPath: "/tmp/fluidaudio-custom-tokenizer")

        XCTAssertEqual(FluidAudioEngine.tokenizerDirectory(modelsDirectory: nil,
                                                           defaultDirectory: fallback), fallback)
        XCTAssertEqual(FluidAudioEngine.tokenizerDirectory(modelsDirectory: custom,
                                                           defaultDirectory: fallback), custom)
    }
}
