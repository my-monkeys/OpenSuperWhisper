import XCTest

@testable import OpenSuperWhisper

/// Answers requests to one reserved host from a canned response and records what was sent.
/// Only that host is claimed, so registering it globally cannot catch another test's traffic.
final class LLMStubProtocol: URLProtocol {
    static let host = "llm.osw-test.invalid"

    enum Reply {
        case http(status: Int, body: String)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    private static var reply: Reply = .http(status: 200, body: "{}")
    private static var sent: [(request: URLRequest, body: Data)] = []

    static func reset(replying reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        self.reply = reply
        sent = []
    }

    static var requests: [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.sent.append((request, Self.bodyData(of: request)))
        let reply = Self.reply
        Self.lock.unlock()

        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The HTTP requests LLM cleanup sends and what `LLMPostProcessor.process` returns for each
/// outcome. Both backends talk to servers the user runs or pays for, so the request shape is a
/// contract with those servers; and `process` must hand back the transcription untouched on
/// every failure, because its result is what gets pasted. Prompt assembly and the length guard
/// arithmetic are covered by `AppContextFormattingTests`; short custom prompts are used here so
/// these tests only see the transport.
final class LLMCleanupRequestTests: XCTestCase {

    private static let endpoint = "http://\(LLMStubProtocol.host):11434"
    private static let input = "so um this is the raw transcription of a dictation"

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences(keychainAccounts: ["aiRemoteAPIKey"])
        URLProtocol.registerClass(LLMStubProtocol.self)
        prefs.aiPostProcessingEnabled = true
        prefs.aiPostProcessingPrompt = "OPEN"
        prefs.aiPostProcessingClosing = "CLOSE"
        prefs.aiOllamaEndpoint = Self.endpoint
        prefs.aiOllamaModel = "llama3.2:3b"
        prefs.aiRemoteEndpoint = "\(LLMStubProtocol.host)/v1/"
        prefs.aiRemoteModel = "llama-3.1-8b-instant"
    }

    override func tearDown() {
        URLProtocol.unregisterClass(LLMStubProtocol.self)
        scratch.restore()
        super.tearDown()
    }

    private func ollamaReply(_ content: String) -> LLMStubProtocol.Reply {
        .http(status: 200, body: String(data: try! JSONSerialization.data(
            withJSONObject: ["message": ["role": "assistant", "content": content]]), encoding: .utf8)!)
    }

    private func remoteReply(_ content: String) -> LLMStubProtocol.Reply {
        .http(status: 200, body: String(data: try! JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]]),
                                        encoding: .utf8)!)
    }

    private func onlyRequest(file: StaticString = #filePath, line: UInt = #line) throws
        -> (request: URLRequest, json: NSDictionary) {
        let requests = LLMStubProtocol.requests
        XCTAssertEqual(requests.count, 1, file: file, line: line)
        let sent = try XCTUnwrap(requests.first, file: file, line: line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? NSDictionary,
                                 file: file, line: line)
        return (sent.request, json)
    }

    // MARK: - Ollama request

    func testOllamaRequest() async throws {
        LLMStubProtocol.reset(replying: ollamaReply("Cleaned."))

        _ = await LLMPostProcessor.process(Self.input, bundleID: nil)

        let (request, json) = try onlyRequest()
        XCTAssertEqual(request.url?.absoluteString, "http://\(LLMStubProtocol.host):11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(json, [
            "model": "llama3.2:3b",
            "stream": false,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": "OPEN\n\nCLOSE"],
                ["role": "user", "content": Self.input],
            ],
        ] as NSDictionary)
    }

    /// The path is appended to whatever the user typed, a trailing slash included.
    func testOllamaPathIsAppendedToTheEndpoint() async throws {
        prefs.aiOllamaEndpoint = " \(Self.endpoint)/ "
        LLMStubProtocol.reset(replying: ollamaReply("Cleaned."))

        _ = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(try onlyRequest().request.url?.absoluteString,
                       "http://\(LLMStubProtocol.host):11434/api/chat")
    }

    /// The reply is trimmed; the transcription is sent exactly as it came in.
    func testOllamaReplyIsTrimmedAndReturned() async {
        LLMStubProtocol.reset(replying: ollamaReply("  So this is the raw transcription.\n"))
        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)
        XCTAssertEqual(result, "So this is the raw transcription.")
    }

    // MARK: - Remote request

    func testRemoteRequestWithAKey() async throws {
        prefs.aiBackend = "remote"
        prefs.aiRemoteAPIKey = "  gsk-test  "
        LLMStubProtocol.reset(replying: remoteReply("Cleaned."))

        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(result, "Cleaned.")
        let (request, json) = try onlyRequest()
        XCTAssertEqual(request.url?.absoluteString, "http://\(LLMStubProtocol.host)/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test",
                       "the stored key is trimmed of spaces")
        XCTAssertEqual(json, [
            "model": "llama-3.1-8b-instant",
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": "OPEN\n\nCLOSE"],
                ["role": "user", "content": Self.input],
            ],
        ] as NSDictionary)
    }

    /// No key, or a key of only spaces, sends no Authorization header at all (no-auth servers).
    func testRemoteRequestWithoutAKeyHasNoAuthorization() async throws {
        prefs.aiBackend = "remote"
        for key in [nil, "   "] as [String?] {
            prefs.aiRemoteAPIKey = key
            LLMStubProtocol.reset(replying: remoteReply("Cleaned."))

            _ = await LLMPostProcessor.process(Self.input, bundleID: nil)

            XCTAssertNil(try onlyRequest().request.value(forHTTPHeaderField: "Authorization"), "\(String(describing: key))")
        }
    }

    // MARK: - Fallbacks

    func testDisabledCleanupSendsNothing() async {
        prefs.aiPostProcessingEnabled = false
        prefs.appContextFormattingEnabled = false
        LLMStubProtocol.reset(replying: ollamaReply("Changed."))

        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(result, Self.input)
        XCTAssertTrue(LLMStubProtocol.requests.isEmpty)
    }

    /// App formatting alone, in an app without a profile, has nothing to ask the model.
    func testFormattingOnlyWithoutAProfileSendsNothing() async {
        prefs.aiPostProcessingEnabled = false
        prefs.appContextFormattingEnabled = true
        prefs.appContextProfiles = [AppContextProfile(bundleIdentifier: "com.example.other", instructions: "x")]
        LLMStubProtocol.reset(replying: ollamaReply("Changed."))

        let result = await LLMPostProcessor.process(Self.input, bundleID: "com.example.app")

        XCTAssertEqual(result, Self.input)
        XCTAssertTrue(LLMStubProtocol.requests.isEmpty)
    }

    func testBlankTranscriptionSendsNothing() async {
        LLMStubProtocol.reset(replying: ollamaReply("Changed."))
        let result = await LLMPostProcessor.process(" \n", bundleID: nil)
        XCTAssertEqual(result, " \n")
        XCTAssertTrue(LLMStubProtocol.requests.isEmpty)
    }

    /// Every way the call can fail returns the transcription unchanged, on both backends.
    func testFailuresReturnTheInputUnchanged() async {
        let outcomes: [(String, LLMStubProtocol.Reply, LLMStubProtocol.Reply)] = [
            ("blank reply", ollamaReply("  \n "), remoteReply("  \n ")),
            ("HTTP 500", .http(status: 500, body: "{}"), .http(status: 500, body: "{}")),
            ("HTTP 401", .http(status: 401, body: "{}"), .http(status: 401, body: "{}")),
            ("not JSON", .http(status: 200, body: "<html>"), .http(status: 200, body: "<html>")),
            ("no choices", .http(status: 200, body: "{}"), .http(status: 200, body: #"{"choices":[]}"#)),
            ("timeout", .failure(.timedOut), .failure(.timedOut)),
            ("offline", .failure(.cannotConnectToHost), .failure(.cannotConnectToHost)),
        ]
        for (label, ollama, remote) in outcomes {
            for (backend, reply) in [("ollama", ollama), ("remote", remote)] {
                prefs.aiBackend = backend
                LLMStubProtocol.reset(replying: reply)

                let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

                XCTAssertEqual(result, Self.input, "\(backend): \(label)")
                XCTAssertEqual(LLMStubProtocol.requests.count, 1, "\(backend): \(label)")
            }
        }
    }

    /// An endpoint that is not a URL fails before sending anything.
    func testUnusableEndpointReturnsTheInput() async {
        prefs.aiBackend = "remote"
        prefs.aiRemoteEndpoint = "   "
        LLMStubProtocol.reset(replying: remoteReply("Changed."))

        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(result, Self.input)
        XCTAssertTrue(LLMStubProtocol.requests.isEmpty)
    }

    // MARK: - Length guard

    /// Ollama and Remote only reject a blank reply: a reply far shorter than the input is
    /// returned, where the built-in model's ratio check would have refused it.
    func testExternalBackendsReturnAShortReply() async {
        for (backend, reply) in [("ollama", ollamaReply("OK.")), ("remote", remoteReply("OK."))] {
            prefs.aiBackend = backend
            LLMStubProtocol.reset(replying: reply)

            let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

            XCTAssertEqual(result, "OK.", backend)
            XCTAssertFalse(LLMPostProcessor.passesLengthGuard(input: Self.input, output: "OK."),
                           "the same reply fails the guard the built-in backend applies")
        }
        XCTAssertTrue(BuiltInLlamaBackend.shared.enforcesLengthRatio)
    }

    /// The built-in backend with no model downloaded (the test storage root has none) is not
    /// ready: nothing runs and the input comes back.
    func testBuiltInBackendWithoutAModelReturnsTheInput() async {
        prefs.aiBackend = "builtin"
        LLMStubProtocol.reset(replying: ollamaReply("Changed."))

        XCTAssertFalse(BuiltInLlamaBackend.shared.isReady)
        let result = await LLMPostProcessor.process(Self.input, bundleID: nil)

        XCTAssertEqual(result, Self.input)
        XCTAssertTrue(LLMStubProtocol.requests.isEmpty)
    }

    // MARK: - Backend selection

    func testBackendSelection() throws {
        prefs.aiRemoteAPIKey = "k"

        prefs.aiBackend = "remote"
        let remote = try XCTUnwrap(LLMPostProcessor.currentBackend() as? RemoteBackend)
        XCTAssertEqual(remote.endpoint, "\(LLMStubProtocol.host)/v1/")
        XCTAssertEqual(remote.model, "llama-3.1-8b-instant")
        XCTAssertEqual(remote.apiKey, "k")

        prefs.aiBackend = "builtin"
        XCTAssertTrue(LLMPostProcessor.currentBackend() is BuiltInLlamaBackend)

        for value in ["ollama", "", "Remote", "lmstudio"] {
            prefs.aiBackend = value
            let ollama = try XCTUnwrap(LLMPostProcessor.currentBackend() as? OllamaBackend, value)
            XCTAssertEqual(ollama.endpoint, Self.endpoint, value)
            XCTAssertEqual(ollama.model, "llama3.2:3b", value)
        }
    }

    /// A fresh install cleans up with Ollama on localhost, and a missing remote key is "".
    func testDefaultBackend() throws {
        scratch.wipe()

        let ollama = try XCTUnwrap(LLMPostProcessor.currentBackend() as? OllamaBackend)
        XCTAssertEqual(ollama.endpoint, "http://localhost:11434")
        XCTAssertEqual(ollama.model, "llama3.2")

        prefs.aiBackend = "remote"
        let remote = try XCTUnwrap(LLMPostProcessor.currentBackend() as? RemoteBackend)
        XCTAssertEqual(remote.endpoint, "https://api.groq.com/openai/v1")
        XCTAssertEqual(remote.apiKey, "")
    }
}
