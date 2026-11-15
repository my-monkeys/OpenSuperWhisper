import Foundation
import os

/// Turning a model's thinking off for a cleanup (#339). `/api/chat` takes `think: false` only from
/// a model that supports switching it: gpt-oss ignores it and wants a level, and a model without
/// thinking may refuse it. So what to send comes from what `/api/show` says the model accepts.
public enum OllamaThinking {
    /// What the switch shows and does until the user chooses: a cleanup gains nothing from thinking
    /// and a model that thinks by default adds seconds to every dictation.
    public static let disabledByDefault = true

    /// The `think` value that turns thinking off for a model.
    enum Value: Equatable {
        case disabled
        case level(String)

        var json: Any {
            switch self {
            case .disabled: false
            case .level(let name): name
            }
        }
    }

    /// The least thinking the model's `thinking.values` allows. `false` when it can be turned off,
    /// else the lowest named level. nil when `/api/show` lists no thinking, or only `true` (the
    /// model thinks and cannot stop), where today's behaviour (no field) is the only safe one.
    static func value(fromShow data: Data) -> Value? {
        guard let values = try? JSONDecoder().decode(ShowResponse.self, from: data).thinking?.values else {
            return nil
        }
        if values.contains(.flag(false)) { return .disabled }
        let levels = values.compactMap { value -> String? in
            if case .level(let name) = value { return name }
            return nil
        }
        return levels.contains("low") ? .level("low") : levels.first.map(Value.level)
    }

    /// The `/api/chat` request body. `think` is left out when nil, so the model keeps its default.
    static func chatBody(model: String, system: String, user: String, think: Value?) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let think { body["think"] = think.json }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static let showTimeout: TimeInterval = 5
    /// Keyed by endpoint and model. Only answers from the server are kept, so a server that was
    /// down is asked again on the next dictation.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Value?]())

    /// The value to send for `model`, asking `/api/show` the first time. nil on any failure.
    static func value(endpoint: URL, model: String) async -> Value? {
        let key = "\(endpoint.absoluteString)|\(model)"
        if let known = cache.withLock({ $0[key] }) { return known }

        var request = URLRequest(url: endpoint.appendingPathComponent("api/show"), timeoutInterval: showTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let value = value(fromShow: data)
        cache.withLock { $0[key] = .some(value) }
        return value
    }

    private struct ShowResponse: Decodable {
        struct Thinking: Decodable { let values: [Entry]? }
        let thinking: Thinking?
    }

    /// One element of `thinking.values`: a boolean for an on/off model, a name for a leveled one.
    private enum Entry: Decodable, Equatable {
        case flag(Bool)
        case level(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else {
                self = .level(try container.decode(String.self))
            }
        }
    }
}
