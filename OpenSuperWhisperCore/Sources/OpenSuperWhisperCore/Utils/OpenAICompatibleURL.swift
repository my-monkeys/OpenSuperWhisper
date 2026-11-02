import Foundation

/// Builds the URL of one resource (`chat/completions`, `models`, `audio/transcriptions`) from the
/// base URL a user typed for an OpenAI-compatible server. One builder for chat, model listing and
/// transcription, so they cannot disagree about where the version segment goes.
public enum OpenAICompatibleURL {
    /// A base that already carries a version segment (`…/openai/v1`, Gemini's
    /// `…/v1beta/openai/`) gets the resource appended as is. A bare host (`http://localhost:4000`)
    /// gets `/v1/` first, the path OpenAI-style servers serve. A missing scheme means plain http://
    /// (LAN servers), a trailing slash is ignored.
    public static func endpoint(base: String, resource: String) -> URL? {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        guard let components = URLComponents(string: base) else { return nil }
        let hasVersion = components.path.split(separator: "/").contains { isVersionSegment($0) }
        return URL(string: base + (hasVersion ? "/" : "/v1/") + resource)
    }

    /// `v1`, `v2`, `v1beta`, `v1alpha2`.
    private static func isVersionSegment(_ segment: Substring) -> Bool {
        segment.range(of: #"^v\d+([a-z]+\d*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
