import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Learning punctuation rules by comparing a sentence we asked for with what came back.
///
/// The failure that matters is a wrong rule, not a missing one. A rule invented from a misheard
/// word gets applied to everything the user dictates afterwards, so silence is the correct
/// answer whenever the comparison is not clear.
final class PunctuationCalibrationTests: XCTestCase {

    private func derive(_ expected: String, _ heard: String) -> [PunctuationCalibration.DerivedRule] {
        PunctuationCalibration.derive(expected: expected, heard: heard)
    }

    // MARK: - English

    func testLearnsQuotes() {
        let rules = derive("He said \"hello\" and walked away.",
                           "He said open quote hello close quote and walked away period")

        XCTAssertEqual(rules.filter { $0.mark == "\"" }.map(\.spoken),
                       ["open quote", "close quote"])
    }

    /// The full stop closing every sentence is parsed so the words line up, then dropped. The
    /// model writes commas and stops by itself, so a rule for them would land beside one that is
    /// already there.
    func testFullStopAndCommaAreNotTaught() {
        let rules = derive("He said \"hello\" and walked away.",
                           "He said open quote hello close quote and walked away period")

        XCTAssertFalse(rules.contains { $0.mark == "." })
        XCTAssertFalse(rules.contains { $0.spoken == "period" })
    }

    /// An opening mark glues to what follows and a closing one to what precedes, read off the
    /// target sentence rather than guessed.
    func testSpacingComesFromTheTargetSentence() {
        let rules = derive("He said \"hello\" and left quietly.",
                           "He said open quote hello close quote and left quietly")

        XCTAssertEqual(rules.first(where: { $0.spoken == "open quote" })?.spacing, .attachesRight)
        XCTAssertEqual(rules.first(where: { $0.spoken == "close quote" })?.spacing, .attachesLeft)
    }

    /// Two marks with no word between them share one stretch of transcript. Guessing which
    /// words belong to which would plant a rule that then rewrites everything the user dictates.
    func testAdjacentMarksTeachNothingRatherThanGuessing() {
        let rules = derive("He said: \"hello\" today",
                           "He said colon open quote hello close quote today")

        XCTAssertFalse(rules.contains { $0.spoken.contains("colon open") },
                       "a run of marks must not be attributed to the first one")
    }

    // MARK: - French

    func testLearnsFrenchPhrasing() {
        let rules = derive("Il a dit « bonjour » puis il est parti.",
                           "Il a dit ouvrez les guillemets bonjour fermez les guillemets puis il est parti point")

        XCTAssertEqual(rules.first(where: { $0.mark == "«" })?.spoken, "ouvrez les guillemets")
        XCTAssertEqual(rules.first(where: { $0.mark == "»" })?.spoken, "fermez les guillemets")
    }

    /// Parentheses are worth teaching for the same reason as quotes: the model never writes one
    /// unless it is spoken.
    func testLearnsParentheses() {
        let rules = derive("He arrived late (again) and said nothing.",
                           "He arrived late open bracket again close bracket and said nothing")

        XCTAssertEqual(rules.first(where: { $0.mark == "(" })?.spoken, "open bracket")
        XCTAssertEqual(rules.first(where: { $0.mark == ")" })?.spoken, "close bracket")
    }

    /// An opening bracket glues to what follows, a closing one to what precedes, or the result
    /// reads `late ( again ) and`.
    func testParenthesesGlueToWhatTheyEnclose() {
        let rules = derive("He arrived late (again) and said nothing.",
                           "He arrived late open bracket again close bracket and said nothing")
        let entries = PunctuationCalibration.entries(from: rules)

        XCTAssertEqual(
            CustomDictionary.apply("She left early open bracket twice close bracket last week",
                                   entries: entries),
            "She left early (twice) last week")
    }

    func testLearnsFrenchParentheses() {
        let rules = derive("Il est arrivé en retard (encore) et n'a rien dit.",
                           "Il est arrivé en retard ouvrez la parenthèse encore fermez la parenthèse et n'a rien dit")

        XCTAssertEqual(rules.first(where: { $0.mark == "(" })?.spoken, "ouvrez la parenthèse")
        XCTAssertEqual(rules.first(where: { $0.mark == ")" })?.spoken, "fermez la parenthèse")
    }

    func testLearnsFrenchColonAndSemicolon() {
        let rules = derive("Elle a répondu : oui ; il n'a rien ajouté.",
                           "Elle a répondu deux points oui point virgule il n'a rien ajouté point")

        XCTAssertEqual(rules.first(where: { $0.mark == ":" })?.spoken, "deux points")
        XCTAssertEqual(rules.first(where: { $0.mark == ";" })?.spoken, "point virgule")
    }

    /// French keeps a space either side of « » : and ; so those rules must not eat one.
    func testFrenchMarksKeepTheirSpaces() {
        let rules = derive("Il a dit « oui » hier",
                           "Il a dit ouvrez les guillemets oui fermez les guillemets hier")

        XCTAssertEqual(rules.first(where: { $0.mark == "«" })?.spacing, .standalone)
        XCTAssertEqual(rules.first(where: { $0.mark == "»" })?.spacing, .standalone)
    }

    /// Accents and capitals differ between the target and the transcript constantly.
    func testMatchingIgnoresAccentsAndCase() {
        let rules = derive("Elle s'est retournée : la porte était ouverte.",
                           "elle s'est retournee deux points la porte etait ouverte point")

        XCTAssertEqual(rules.first(where: { $0.mark == ":" })?.spoken, "deux points")
    }

    // MARK: - Saying nothing

    /// The common case: the model punctuated by itself and the person said no punctuation at
    /// all. Nothing was substituted, so there is nothing to learn.
    func testLearnsNothingWhenThePunctuationWasNotSpoken() {
        XCTAssertTrue(derive("He said \"hello\" today", "He said \"hello\" today").isEmpty)
    }

    func testLearnsNothingFromAnEmptyTranscript() {
        XCTAssertTrue(derive("He said \"hello\" today", "").isEmpty)
    }

    /// A hyphen inside a word is not punctuation anybody reads aloud.
    func testHyphenInsideAWordIsNotARule() {
        let rules = derive("« Tu viens ? » demanda-t-il",
                           "ouvrez les guillemets tu viens point d'interrogation fermez les guillemets demanda-t-il")

        XCTAssertFalse(rules.contains { $0.mark == "-" })
    }

    /// An apostrophe is not in the learnable set, so "n'était" never produces a rule.
    func testApostropheIsNotARule() {
        let rules = derive("Personne n'était là : voilà.", "personne n'était là deux points voilà")
        XCTAssertEqual(rules.map(\.mark), [":"])
    }

    /// A long run of misheard words between two anchors is not a phrasing, it is a mistake.
    func testRefusesImplausiblyLongPhrasings() {
        let rules = derive("Yes: no.",
                           "Yes " + String(repeating: "wandering ", count: 12) + "no")

        XCTAssertTrue(rules.filter { $0.mark == ":" }.isEmpty)
    }

    // MARK: - Turning them into dictionary rules

    /// Four sentences each containing a colon should leave one colon rule holding every
    /// phrasing, not four rules.
    func testGathersPhrasingsPerMark() {
        let entries = PunctuationCalibration.entries(from: [
            .init(spoken: "colon", mark: ":", spacing: .attachesLeft),
            .init(spoken: "two points", mark: ":", spacing: .attachesLeft),
            .init(spoken: "semicolon", mark: ";", spacing: .attachesLeft),
        ])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].replacement, ":")
        XCTAssertEqual(entries[0].original, "colon")
        XCTAssertEqual(entries[0].alternates, ["two points"])
    }

    func testDoesNotRepeatTheSamePhrasing() {
        let entries = PunctuationCalibration.entries(from: [
            .init(spoken: "colon", mark: ":", spacing: .attachesLeft),
            .init(spoken: "Colon", mark: ":", spacing: .attachesLeft),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].alternates.isEmpty)
    }

    /// End to end: what is learned has to survive being applied. This is the whole point, and
    /// it is where an opening and a closing quote being the same character shows up.
    func testLearnedRulesProduceTheTargetSentence() {
        let rules = derive("He said \"hello\" and walked away.",
                           "He said open quote hello close quote and walked away period")
        let entries = PunctuationCalibration.entries(from: rules)

        let applied = CustomDictionary.apply(
            "She said open quote goodbye close quote and stayed", entries: entries)

        // "period" is deliberately absent: the model writes full stops itself, so we teach no
        // rule for them and the word would be left standing.
        XCTAssertEqual(applied, "She said \"goodbye\" and stayed")
    }

    /// The same character pulling in opposite directions must stay two rules.
    func testOpeningAndClosingQuotesDoNotMerge() {
        let entries = PunctuationCalibration.entries(from: [
            .init(spoken: "open quote", mark: "\"", spacing: .attachesRight),
            .init(spoken: "close quote", mark: "\"", spacing: .attachesLeft),
        ])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].spacing, .attachesRight)
        XCTAssertEqual(entries[1].spacing, .attachesLeft)
    }

    // MARK: - The sentences we ship

    func testEveryShippedSentenceIsLearnable() {
        for sentence in PunctuationCalibration.english + PunctuationCalibration.french {
            let marks = sentence.text.filter { PunctuationCalibration.learnableMarks.contains($0) }
            XCTAssertFalse(marks.isEmpty, "\(sentence.id) teaches nothing")
        }
    }

    func testBothLanguagesOfferSeveralSentences() {
        XCTAssertEqual(PunctuationCalibration.sentences(for: "en").count, 4)
        XCTAssertEqual(PunctuationCalibration.sentences(for: "fr").count, 4)
        XCTAssertEqual(PunctuationCalibration.sentences(for: "fr-FR").first?.language, "fr")
    }
}
