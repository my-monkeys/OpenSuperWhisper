import CryptoKit
import Foundation
import OpenSuperWhisperCore

/// A word offered for the dictionary and not answered yet (#169).
struct DictionarySuggestion: Codable, Equatable, Identifiable, Sendable {
    let term: String
    /// What the engine had written instead, so the user can tell where the word came from.
    let heard: String

    var id: String { term.lowercased() }

    /// Whether what the engine wrote is another word, not the same one in another case. Then
    /// adding it has to turn the one into the other, or the next dictation writes it wrong again.
    var correctsHeard: Bool {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return !heard.isEmpty && heard.caseInsensitiveCompare(term) != .orderedSame
    }

    /// The dictionary entry Add creates: a correction from what was heard to the term, so
    /// "Maxime" is written "Maxim" from then on, or the term alone when only its case was wrong.
    /// Either way the term is what gets boosted and named to the cleanup model.
    var entry: CustomDictionaryEntry {
        CustomDictionaryEntry(original: correctsHeard ? heard.trimmingCharacters(in: .whitespacesAndNewlines) : term,
                              replacement: term)
            .withDefaultBoost()
    }
}

/// The words the corrections after a dictation offered for the dictionary, and the ones the
/// user turned down (#169).
///
/// Suggests, never adds on its own: a word goes into the dictionary only from Add. A word the
/// user refused, or deleted from the dictionary, is never offered again, whatever its case.
/// The dictionary's Suggested list and the notice after a dictation are two views of this one
/// list, so answering in either answers both.
@MainActor
final class DictionarySuggestions: ObservableObject {
    static let shared = DictionarySuggestions()

    @Published private(set) var pending: [DictionarySuggestion]

    /// The oldest go first past this. An unanswered suggestion is the user's own correction
    /// kept on disk, and one nobody looked at in twenty dictations is not going to be.
    static let maxPending = 20

    private let prefs: AppPreferences

    init(prefs: AppPreferences = .shared) {
        self.prefs = prefs
        pending = prefs.dictionarySuggestionsData
            .flatMap { try? JSONDecoder().decode([DictionarySuggestion].self, from: $0) } ?? []
    }

    #if DEBUG
    /// Re-reads the list, for the snapshot probe, which seeds it after the store was made.
    func reload() {
        pending = prefs.dictionarySuggestionsData
            .flatMap { try? JSONDecoder().decode([DictionarySuggestion].self, from: $0) } ?? []
    }
    #endif

    /// Adds the candidates that are new, and returns them in order for the notice. A term
    /// already in the dictionary, already offered, or ever refused is left out.
    @discardableResult
    func offer(_ candidates: [DictionaryCandidates.Candidate]) -> [DictionarySuggestion] {
        var added: [DictionarySuggestion] = []
        for candidate in candidates where isNew(candidate.term)
            && !added.contains(where: { $0.id == candidate.term.lowercased() }) {
            added.append(DictionarySuggestion(term: candidate.term, heard: candidate.heard))
        }
        guard !added.isEmpty else { return [] }
        save(Array((pending + added).suffix(Self.maxPending)))
        return added
    }

    /// Whether `term` may be offered: not in the dictionary in any form, not pending, never
    /// refused.
    func isNew(_ term: String) -> Bool {
        let lowered = term.lowercased()
        let entries = prefs.customDictionaryEntries
        let inDictionary = entries.contains { entry in
            ([entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)] + entry.triggers)
                .contains { $0.lowercased() == lowered }
        }
        return !inDictionary
            && !pending.contains { $0.id == lowered }
            && !Set(prefs.dictionaryRefusedWords).contains(digest(term))
    }

    /// Adds the term to the dictionary, see `DictionarySuggestion.entry`. It used to be added as
    /// a word that rewrote only itself, so accepting "Maxim" for "Maxime" changed nothing in the
    /// next dictation.
    func accept(_ suggestion: DictionarySuggestion) {
        remove(suggestion)
        guard !prefs.customDictionaryEntries.contains(where: {
            $0.trimmedReplacement.caseInsensitiveCompare(suggestion.term) == .orderedSame
        }) else { return }
        prefs.customDictionaryEntries.append(
            suggestion.entry)
        NotificationCenter.default.post(name: .customDictionaryDidChange, object: nil)
    }

    func refuse(_ suggestion: DictionarySuggestion) {
        remove(suggestion)
        neverOffer(suggestion.term)
    }

    /// A word deleted from the dictionary was a word the user did not want there: offering it
    /// back after the next correction would undo their decision.
    func noteDeleted(_ entry: CustomDictionaryEntry) {
        let term = entry.trimmedReplacement
        guard !entry.isRegex, term.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        neverOffer(term)
    }

    /// Drops every word waiting for an answer, when the setting is turned off: what was heard
    /// is part of a dictation, and nobody is going to be asked about it any more.
    func clearPending() {
        save([])
    }

    /// Case-insensitive, and keyed rather than a plain hash: a plain SHA-256 of a short word is
    /// undone by hashing a word list, and an address someone refused should not be one guess
    /// away on disk. See `dictionaryRefusedWords`.
    func digest(_ term: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(term.lowercased().utf8), using: refusalKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Read on first use: most sessions never refuse anything.
    private lazy var refusalKey = Self.loadRefusalKey()

    static let refusalKeyAccount = "dictionaryRefusalKey"

    /// A random key made once per install and kept in the Keychain, apart from the digests it
    /// keys. Should the Keychain refuse it, refusals still hold until the app quits.
    private static func loadRefusalKey() -> SymmetricKey {
        if let stored = Keychain.read(refusalKeyAccount), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        Keychain.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: refusalKeyAccount)
        return key
    }

    private func neverOffer(_ term: String) {
        let digest = digest(term)
        guard !prefs.dictionaryRefusedWords.contains(digest) else { return }
        prefs.dictionaryRefusedWords.append(digest)
    }

    private func remove(_ suggestion: DictionarySuggestion) {
        save(pending.filter { $0.id != suggestion.id })
    }

    private func save(_ suggestions: [DictionarySuggestion]) {
        pending = suggestions
        prefs.dictionarySuggestionsData = suggestions.isEmpty ? nil : try? JSONEncoder().encode(suggestions)
    }
}

extension Notification.Name {
    /// The dictionary changed outside the Dictionary page, so an open one re-reads it.
    static let customDictionaryDidChange = Notification.Name("CustomDictionaryDidChange")
}
