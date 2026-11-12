import SwiftUI
import OpenSuperWhisperCore

/// What the Report card holds while it is open (#168): the problem picked, the text it should
/// have written, the comment, and for a wrong word or name the two words that can go straight
/// into the dictionary.
struct ReportDraft: Equatable {
    var problem: TranscriptionReport.Problem?
    var comment = ""
    var writtenAs = ""
    var shouldBe = ""
    /// The text the dictation produced, which `expected` starts as.
    var output = ""
    /// What it should have written. It starts as the output, so a long dictation is fixed in
    /// place instead of typed again.
    var expected = ""

    /// A fresh draft for this dictation.
    init(for recording: Recording) {
        output = recording.transcription
        expected = recording.transcription
    }

    init(problem: TranscriptionReport.Problem? = nil, comment: String = "",
         writtenAs: String = "", shouldBe: String = "", output: String = "", expected: String = "") {
        self.problem = problem
        self.comment = comment
        self.writtenAs = writtenAs
        self.shouldBe = shouldBe
        self.output = output
        self.expected = expected
    }

    /// What a report cannot do without. The audio alone gives the same text on the maintainer's
    /// Mac, so a text problem needs what should have come out; "Something else" has no text to
    /// correct and needs the comment instead.
    enum Missing: Equatable {
        case problem, expectedText, comment
    }

    var missing: Missing? {
        guard let problem else { return .problem }
        if problem == .other {
            return comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .comment : nil
        }
        return correctedText == nil ? .expectedText : nil
    }

    var canSave: Bool { missing == nil }

    /// The field is offered for every problem but "Something else".
    var asksForExpectedText: Bool { problem != nil && problem != .other }

    /// What it should have written, once it says something other than what came out.
    var correctedText: String? {
        guard asksForExpectedText else { return nil }
        let corrected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty,
              corrected != output.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return corrected
    }

    /// The word fields are only offered, and only kept, for a word or a name.
    var showsWordFields: Bool { problem?.concernsAWord == true }

    /// The dictionary entry the word fields describe, nil until "Should be" holds something.
    /// With "Written as" filled in and different, a correction from one to the other; without
    /// it, a new word the model is primed with, as the Dictionary page's "New word" makes it.
    var dictionaryEntry: CustomDictionaryEntry? {
        let correct = shouldBe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsWordFields, !correct.isEmpty else { return nil }
        let wrong = writtenAs.trimmingCharacters(in: .whitespacesAndNewlines)
        if wrong.isEmpty || wrong.caseInsensitiveCompare(correct) == .orderedSame {
            return CustomDictionaryEntry(original: correct, replacement: correct)
        }
        return CustomDictionaryEntry(original: wrong, replacement: correct)
    }

    func report(for recording: Recording, languageSetting: String?, appDetails: String) -> TranscriptionReport? {
        guard let problem else { return nil }
        return TranscriptionReport(recording: recording, problem: problem, comment: comment,
                                   writtenAs: showsWordFields ? writtenAs : nil,
                                   shouldBe: showsWordFields ? shouldBe : nil,
                                   expectedText: correctedText,
                                   languageSetting: languageSetting, appDetails: appDetails)
    }

    /// Adds the entry to the user's dictionary. A literal rule that already writes the same thing
    /// takes the new phrasing as an alternate instead, as `CustomDictionary.merged` would fold
    /// it on the next launch; every other rule is left exactly as it was.
    static func adding(_ entry: CustomDictionaryEntry, to entries: [CustomDictionaryEntry]) -> [CustomDictionaryEntry] {
        var entries = entries
        guard let index = entries.firstIndex(where: {
            !$0.isRegex && $0.spacing == entry.spacing && $0.trimmedReplacement == entry.trimmedReplacement
        }) else {
            entries.append(entry)
            return entries
        }
        for trigger in entry.triggers where !entries[index].triggers.contains(where: {
            $0.caseInsensitiveCompare(trigger) == .orderedSame
        }) {
            entries[index].alternates.append(trigger)
        }
        return entries
    }
}

extension TranscriptionReport.Problem {
    /// In the order the card offers them.
    static let offered: [Self] = [.wrongWord, .wrongName, .wrongLanguage, .cleanupChangedMeaning, .other]

    var label: LocalizedStringKey {
        switch self {
        case .wrongWord: return "Wrong word"
        case .wrongName: return "Wrong name"
        case .wrongLanguage: return "Wrong language"
        case .cleanupChangedMeaning: return "Cleanup changed the meaning"
        case .other: return "Something else"
        }
    }

    /// For the GitHub issue, which is read by the maintainers in English whatever the app's language.
    var issueLabel: String {
        switch self {
        case .wrongWord: return "Wrong word"
        case .wrongName: return "Wrong name"
        case .wrongLanguage: return "Wrong language"
        case .cleanupChangedMeaning: return "Cleanup changed the meaning"
        case .other: return "Something else"
        }
    }
}
