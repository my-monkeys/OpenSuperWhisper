import Foundation

/// The pure decisions behind the Remote cleanup API key field (#273).
enum RemoteCleanupKey {
    /// Shortest key whose last four characters can be shown without giving away much of it.
    private static let minimumLengthForSuffix = 8

    /// "…a1b2": which key is in place, without revealing it. Nil when there is no key, or when it
    /// is so short that its end would be most of it.
    static func suffixHint(of key: String?) -> String? {
        guard let key, key.count >= minimumLengthForSuffix else { return nil }
        return "…" + key.suffix(4)
    }

    /// Copying the Remote engine's config overwrites the cleanup key: that needs a confirmation
    /// only when it would replace a key someone typed with a different one (it replaced an
    /// OpenRouter key with a Groq one without a word).
    static func copyNeedsConfirmation(current: String, incoming: String) -> Bool {
        !current.isEmpty && current != incoming
    }
}
