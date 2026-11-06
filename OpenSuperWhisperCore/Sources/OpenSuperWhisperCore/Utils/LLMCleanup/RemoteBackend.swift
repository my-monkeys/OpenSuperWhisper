import Foundation

/// LLM cleanup backed by any OpenAI-compatible `/v1/chat/completions` server (Groq, OpenAI,
/// LiteLLM, a self-hosted box…), independent of the Remote *transcription* engine — this has
/// its own endpoint/model/key so cleanup can run against a different server than transcription.
struct RemoteBackend: LLMCleanupBackend {
    let endpoint: String
    let model: String
    let apiKey: String
    /// Adds the service's "no reasoning" fields to the request (see `RemoteService.reasoningFields`).
    var disableReasoning = false

    /// A remote server is a separate process we can't cheaply probe synchronously here; treat
    /// it as "ready" and let `generate` fail gracefully (the caller falls back to the raw text).
    /// The settings UI's "Test Connection" does the explicit, user-triggered probe.
    var isReady: Bool { true }

    /// The id as the user typed it, e.g. `google/gemini-2.5-flash-lite`.
    var modelLabel: String { model.trimmingCharacters(in: .whitespaces) }

    /// The cleanup request exactly as `generate` would send it.
    ///
    /// Split out so a test can inspect what leaves the machine: with the build and the send in
    /// one function there is no moment at which the request exists, and this is one of the sinks
    /// the field's text must never reach (#89). Not `async` because it has nothing to wait for —
    /// the caller wraps it, the test may not need to.
    func request(for user: String, system: String) throws -> URLRequest {
        guard let url = LLMPostProcessor.chatEndpoint(base: endpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        body.merge(Self.reasoningFields(endpoint: endpoint, model: model, disabled: disableReasoning)) { $1 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func generate(system: String, user: String) async throws -> String {
        // Named apart from the method: a local called `request` would be in scope in its own
        // initializer and the call would not resolve.
        let urlRequest = try request(for: user, system: system)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CleanupHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
        guard let content = LLMPostProcessor.extractChatContent(from: data) else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    /// A real, tiny chat request, because `GET /models` proves nothing about the key or the model:
    /// OpenRouter answers it 200 without any key, so a wrong key stayed green until every cleanup
    /// failed in silence. Used by the settings "Test Connection".
    static func probe(endpoint: String, model: String, apiKey: String,
                      disableReasoning: Bool = false) async -> LLMStatus {
        guard let url = LLMPostProcessor.chatEndpoint(base: endpoint) else { return .unreachable }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // The reasoning fields go in the probe too, so a model that refuses them fails here, in
        // the message the settings show, and not silently on the first dictation.
        var body: [String: Any] = [
            "model": model, "max_tokens": 8, "stream": false,
            "messages": [["role": "user", "content": "ping"]],
        ]
        body.merge(reasoningFields(endpoint: endpoint, model: model, disabled: disableReasoning)) { $1 }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .unreachable }
        request.httpBody = payload
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return probeStatus(code: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, model: model)
        } catch {
            return .unreachable
        }
    }

    static func reasoningFields(endpoint: String, model: String, disabled: Bool) -> [String: Any] {
        disabled
            ? RemoteService.reasoningFields(service: RemoteService.detect(url: endpoint), model: model)
            : [:]
    }

    /// What the answer to the probe means. A 400 only counts as a missing model when its message
    /// names the model; other 400s (a bad parameter) are a failure to report as the server worded it.
    static func probeStatus(code: Int, body: Data, model: String) -> LLMStatus {
        let message = CleanupHTTPError.serverMessage(in: body)
        switch code {
        case 200..<300:
            return LLMPostProcessor.extractChatContent(from: body) != nil
                ? .ok : .requestFailed(message ?? "Unexpected reply")
        case 401, 403:
            return .authFailed(message)
        case 404:
            return .modelMissing(model)
        case 400 where message?.localizedCaseInsensitiveContains("model") == true:
            return .modelMissing(model)
        default:
            return .requestFailed(CleanupHTTPError(status: code, body: body).errorDescription ?? "HTTP \(code)")
        }
    }
}
