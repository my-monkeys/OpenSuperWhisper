import Foundation

/// LLM cleanup backed by Ollama's HTTP API (http://localhost:11434 by default).
/// The opt-in "power user" backend — runs whatever model the user has pulled,
/// including large ones. See `BuiltInLlamaBackend` for the zero-setup default.
struct OllamaBackend: LLMCleanupBackend {
    let endpoint: String
    let model: String

    /// Ollama is a separate process we can't cheaply probe synchronously here; treat it as
    /// "ready" and let `generate` fail gracefully (the caller falls back to the raw text).
    /// The settings UI uses `checkConnection` for an explicit, user-triggered probe.
    var isReady: Bool { true }

    func generate(system: String, user: String) async throws -> String {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": 0],
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
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }

    /// Probes the Ollama server (GET /api/tags) and checks whether the configured model is
    /// pulled. Used by the settings "Test" button so the user knows the cleanup will work.
    static func checkConnection(endpoint: String, model: String) async -> LLMStatus {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            return .unreachable
        }
        let request = URLRequest(url: base.appendingPathComponent("api/tags"), timeoutInterval: 5)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unreachable
            }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let wanted = model.trimmingCharacters(in: .whitespaces)
            // Ollama lists models as "name:tag" (e.g. "llama3.2:latest"); match name or name:tag.
            let found = tags.models.contains { $0.name == wanted || $0.name.hasPrefix(wanted + ":") }
            return found ? .ok : .modelMissing(wanted)
        } catch {
            return .unreachable
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
}
