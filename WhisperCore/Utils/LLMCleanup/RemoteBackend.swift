import Foundation

/// LLM cleanup backed by any OpenAI-compatible `/v1/chat/completions` server (Groq, OpenAI,
/// LiteLLM, a self-hosted box…), independent of the Remote *transcription* engine — this has
/// its own endpoint/model/key so cleanup can run against a different server than transcription.
struct RemoteBackend: LLMCleanupBackend {
    let endpoint: String
    let model: String
    let apiKey: String

    /// A remote server is a separate process we can't cheaply probe synchronously here; treat
    /// it as "ready" and let `generate` fail gracefully (the caller falls back to the raw text).
    /// The settings UI's "Test Connection" does the explicit, user-triggered probe.
    var isReady: Bool { true }

    func generate(system: String, user: String) async throws -> String {
        guard let url = LLMPostProcessor.chatEndpoint(base: endpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let content = LLMPostProcessor.extractChatContent(from: data) else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}
