import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The exact HTTP request the remote engine sends, built from fixed preferences and settings,
/// without touching the network: first through the builders, then through `transcribeAudio`
/// against a stub server, so how it wires them together is pinned too.
///
/// Users point this engine at servers we do not control (Groq, speaches, LiteLLM, their own
/// proxies), so the wire format is a contract: field names, which fields are left out, the
/// Authorization header only when a key is set. The extraction moved this code and its
/// preference reads behind a protocol; the bytes must not change.
final class RemoteEngineRequestTests: XCTestCase {

    private static let defaultsKeys = ["remoteServerURL", "remoteServerModel",
                                       "remoteServerTimeoutEnabled", "remoteServerTimeoutSeconds"]
    private var savedDefaults: [String: Any] = [:]
    private var savedAPIKey: String?
    /// The API key lives in the test Keychain service, which the scheme's parallel test
    /// processes share: without the lock the account tests in another process read this key.
    private var keychainLock: KeychainLock?

    override func setUp() {
        super.setUp()
        keychainLock = KeychainLock()
        for key in Self.defaultsKeys {
            savedDefaults[key] = DefaultsStore.current.object(forKey: key)
        }
        savedAPIKey = AppPreferences.shared.remoteServerAPIKey
    }

    private func restoreDefaults() {
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] {
                DefaultsStore.current.set(value, forKey: key)
            } else {
                DefaultsStore.current.removeObject(forKey: key)
            }
        }
        AppPreferences.shared.remoteServerAPIKey = savedAPIKey
    }

    private var tempDirectories: [URL] = []

    override func tearDown() {
        tempDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        tempDirectories = []
        StubServer.reset()
        restoreDefaults()
        keychainLock?.release()
        keychainLock = nil
        super.tearDown()
    }

    private func engine(url: String, model: String = "", apiKey: String? = nil,
                        timeoutEnabled: Bool = true, timeoutSeconds: Double = 60,
                        stubbed: Bool = false) async throws -> RemoteEngine {
        let prefs = AppPreferences.shared
        prefs.remoteServerURL = url
        prefs.remoteServerModel = model
        prefs.remoteServerAPIKey = apiKey
        prefs.remoteServerTimeoutEnabled = timeoutEnabled
        prefs.remoteServerTimeoutSeconds = timeoutSeconds
        let engine = stubbed ? RemoteEngine(sessionConfiguration: StubServer.configuration) : RemoteEngine()
        try await engine.initialize()
        return engine
    }

    private func settings(language: String = "en", translate: Bool = false,
                          temperature: Double = 0, prompt: String = "") -> Settings {
        var settings = Fixtures.pinnedSettings()
        settings.selectedLanguage = language
        settings.translateToEnglish = translate
        settings.temperature = temperature
        settings.initialPrompt = prompt
        return settings
    }

    /// What `transcribeAudio` sends for `settings`, with the boundary and audio fixed, rebuilt
    /// from its builders. The tests under "transcribeAudio" below check the real call.
    private func request(_ engine: RemoteEngine, _ settings: Settings) throws -> URLRequest {
        let clip = RemoteEngine.clipParameters(for: settings)
        let endpoint = try XCTUnwrap(engine.endpoint(for: clip.action))
        return engine.makeRequest(endpoint: endpoint, boundary: "BOUNDARY", filename: "clip.wav",
                                  audioData: Data("RIFFDATA".utf8), language: clip.language,
                                  temperature: clip.temperature, prompt: clip.prompt)
    }

    private func body(_ request: URLRequest) throws -> String {
        try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
    }

    private func field(_ name: String, _ value: String) -> String {
        "--BOUNDARY\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    private let fileField = "--BOUNDARY\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n"
        + "Content-Type: audio/wav\r\n\r\nRIFFDATA\r\n"
    private let closing = "--BOUNDARY--\r\n"

    /// Every optional field set. Preferences are trimmed when the engine initializes, the
    /// prompt when the body is built; the fields go out in this order.
    func testFullRequestCarriesTheKeyAndEveryField() async throws {
        let engine = try await engine(url: "  https://api.example.test/openai/v1/  ",
                                      model: "  whisper-large-v3  ", apiKey: "  sk-test  ")
        let request = try request(engine, settings(language: "fr", temperature: 0.2,
                                                   prompt: "  Bonjour, Mme Dupont.  "))

        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.example.test/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Content-Type": "multipart/form-data; boundary=BOUNDARY",
            "Authorization": "Bearer sk-test",
        ])
        XCTAssertEqual(try body(request),
                       field("response_format", "json")
                       + field("model", "whisper-large-v3")
                       + field("language", "fr")
                       + field("temperature", "0.2")
                       + field("prompt", "Bonjour, Mme Dupont.")
                       + fileField + closing)
    }

    /// No key, no model, automatic language, temperature 0 and a blank prompt: only the response
    /// format and the file go out, so the server's own defaults apply, and no Authorization
    /// header is sent at all (no-auth servers reject an empty bearer). A scheme-less URL is
    /// sent over plain http.
    func testMinimalRequestLeavesEveryOptionalFieldOut() async throws {
        let engine = try await engine(url: "192.168.1.20:8000")
        let request = try request(engine, settings(language: "auto", temperature: 0, prompt: "  \n "))

        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:8000/v1/audio/transcriptions")
        XCTAssertEqual(request.allHTTPHeaderFields,
                       ["Content-Type": "multipart/form-data; boundary=BOUNDARY"])
        XCTAssertEqual(try body(request), field("response_format", "json") + fileField + closing)
    }

    /// An empty key is the same as no key.
    func testEmptyKeySendsNoAuthorization() async throws {
        let engine = try await engine(url: "https://api.example.test", apiKey: "   ")
        let request = try request(engine, settings())
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// Translation goes to the translations endpoint and drops the language, which that endpoint
    /// ignores (its output is always English). Temperature and prompt are still sent.
    func testTranslationUsesItsEndpointAndDropsTheLanguage() async throws {
        let engine = try await engine(url: "https://api.example.test/v1", model: "whisper-1")
        let request = try request(engine, settings(language: "fr", translate: true,
                                                   temperature: 0.4, prompt: "Paris"))

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/audio/translations")
        XCTAssertEqual(try body(request),
                       field("response_format", "json")
                       + field("model", "whisper-1")
                       + field("temperature", "0.4")
                       + field("prompt", "Paris")
                       + fileField + closing)
    }

    /// The remote engine forwards the user's prompt and nothing else: no dictionary boost and
    /// never the focused field's text, which would post the user's own writing to a third-party
    /// server (#89).
    func testClipParametersSendOnlyTheUserPrompt() {
        var settings = settings(language: "de", temperature: 0.3, prompt: "Mein Prompt")
        settings.customDictionaryEnabled = true
        settings.customDictionaryBoostEnabled = true
        settings.customDictionaryEntries = [CustomDictionaryEntry(original: "osw", replacement: "OpenSuperWhisper")]
        settings.useSurroundingTextAsContext = true
        settings.focusedText = "Text already in the field"

        let clip = RemoteEngine.clipParameters(for: settings)
        XCTAssertEqual(clip.action, "transcriptions")
        XCTAssertEqual(clip.language, "de")
        XCTAssertEqual(clip.temperature, 0.3)
        XCTAssertEqual(clip.prompt, "Mein Prompt")
    }

    /// The timeout lives on the session, since URLSession ignores a POST's own timeout: the
    /// user's value, at least one second, and a year when the timeout is turned off.
    func testSessionTimeoutsFollowThePreferences() async throws {
        let cases: [(enabled: Bool, seconds: Double, expected: TimeInterval)] = [
            (true, 60, 60), (true, 300, 300), (true, 0.2, 1), (false, 60, 31_536_000),
        ]
        for testCase in cases {
            let engine = try await engine(url: "https://api.example.test",
                                          timeoutEnabled: testCase.enabled,
                                          timeoutSeconds: testCase.seconds)
            let session = engine.makeSession()
            defer { session.invalidateAndCancel() }
            XCTAssertEqual(session.configuration.timeoutIntervalForRequest, testCase.expected, "\(testCase)")
            XCTAssertEqual(session.configuration.timeoutIntervalForResource, testCase.expected, "\(testCase)")
        }
    }

    /// A blank server URL fails initialization rather than producing an engine with nowhere to
    /// send audio.
    func testBlankServerFailsToInitialize() async throws {
        do {
            _ = try await engine(url: "   ")
            XCTFail("initialized with no server")
        } catch TranscriptionError.contextInitializationFailed {
        }
    }

    // MARK: transcribeAudio

    /// A file named as a recording would be, holding fixed bytes: the engine sends the file as is.
    private func clipFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent("clip.wav")
        try Data("RIFFDATA".utf8).write(to: url)
        return url
    }

    /// The real call, end to end against the stub: the request is the one the builders give
    /// (with a fresh "Boundary-<UUID>" each time, normalised here), the file keeps its name, and
    /// the server's text goes through the same post-processing as a local engine's (#101). The
    /// dictionary boost and the focused field's text are set and must not leave the Mac (#89).
    func testTranscribeSendsTheBuiltRequestAndPostProcessesTheReply() async throws {
        StubServer.reset(responses: [(200, #"{"text":"osw"}"#)])
        let engine = try await engine(url: "https://api.example.test/v1", model: "whisper-1",
                                      apiKey: "sk-test", stubbed: true)
        var settings = settings(language: "fr", temperature: 0.2, prompt: "Mein Prompt")
        settings.customDictionaryEnabled = true
        settings.customDictionaryBoostEnabled = true
        settings.customDictionaryEntries = [CustomDictionaryEntry(original: "osw", replacement: "OpenSuperWhisper")]
        settings.useSurroundingTextAsContext = true
        settings.focusedText = "Text already in the field"

        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings)

        XCTAssertEqual(text, "OpenSuperWhisper", "the server's text was not post-processed")
        let sent = StubServer.requests
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.url, "https://api.example.test/v1/audio/transcriptions")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
        let contentType = try XCTUnwrap(request.headers["Content-Type"])
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix), contentType)
        let boundary = String(contentType.dropFirst(prefix.count))
        XCTAssertNotNil(boundary.range(of: #"^Boundary-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$"#,
                                       options: .regularExpression), boundary)

        let body = try XCTUnwrap(String(data: request.body, encoding: .utf8))
        XCTAssertEqual(body.replacingOccurrences(of: boundary, with: "BOUNDARY"),
                       field("response_format", "json")
                       + field("model", "whisper-1")
                       + field("language", "fr")
                       + field("temperature", "0.2")
                       + field("prompt", "Mein Prompt")
                       + fileField + closing)
        XCTAssertFalse(body.contains("OpenSuperWhisper"), "the dictionary boost was sent")
        XCTAssertFalse(body.contains("Text already in the field"), "the focused text was sent")
    }

    /// 401 and 403 are not retried and name the problem from whether a key is set.
    func testUnauthorizedWithoutAKeyAsksForOne() async throws {
        StubServer.reset(responses: [(401, #"{"error":"unauthorized"}"#)])
        let engine = try await engine(url: "https://api.example.test", stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("a 401 transcribed")
        } catch RemoteError.missingAPIKey {
        }
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    func testForbiddenWithAKeyRejectsIt() async throws {
        StubServer.reset(responses: [(403, #"{"error":"forbidden"}"#)])
        let engine = try await engine(url: "https://api.example.test", apiKey: "sk-wrong", stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("a 403 transcribed")
        } catch RemoteError.invalidAPIKey {
        }
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    /// A real client error is reported with the server's own message after one request: retrying
    /// the same audio would only fail again.
    func testClientErrorIsReportedWithoutRetrying() async throws {
        StubServer.reset(responses: [(400, #"{"error":{"message":"bad audio"}}"#)])
        let engine = try await engine(url: "https://api.example.test", stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("a 400 transcribed")
        } catch RemoteError.api(let status, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "bad audio")
        }
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    /// A 503 is retried with the same request, and the second answer is used. Waits through the
    /// real first backoff (half a second).
    func testServerErrorIsRetriedWithTheSameRequest() async throws {
        StubServer.reset(responses: [(503, "busy"), (200, #"{"text":"bonjour"}"#)])
        let engine = try await engine(url: "https://api.example.test", stubbed: true)

        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings())

        XCTAssertEqual(text, "bonjour")
        let sent = StubServer.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.body, sent.last?.body)
        XCTAssertEqual(sent.first?.headers, sent.last?.headers)
    }
}

/// A server that answers from a queue and records what reached it. URLProtocol only sees a body
/// stream, never `httpBody`, so the stream is read out. Static state: the engine builds a new
/// session per attempt, and the tests in this class run one at a time.
private final class StubServer: URLProtocol {
    struct Received {
        let url: String
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var responses: [(status: Int, body: String)] = []
    private static var received: [Received] = []

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [StubServer.self]
        return config
    }

    static func reset(responses: [(Int, String)] = []) {
        lock.withLock {
            self.responses = responses.map { (status: $0.0, body: $0.1) }
            received = []
        }
    }

    static var requests: [Received] { lock.withLock { received } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Received(url: request.url?.absoluteString ?? "",
                              method: request.httpMethod ?? "",
                              headers: request.allHTTPHeaderFields ?? [:],
                              body: Self.readBody(of: request))
        let answer: (status: Int, body: String) = Self.lock.withLock {
            Self.received.append(record)
            return Self.responses.isEmpty ? (500, "no stubbed response") : Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
