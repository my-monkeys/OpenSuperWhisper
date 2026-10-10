import XCTest
@testable import OpenSuperWhisper

/// The exact HTTP request the remote engine would send, built from fixed preferences and
/// settings, without touching the network.
///
/// Users point this engine at servers we do not control (Groq, speaches, LiteLLM, their own
/// proxies), so the wire format is a contract: field names, which fields are left out, the
/// Authorization header only when a key is set. The extraction moves this code and its
/// preference reads behind a protocol; the bytes must not change.
final class RemoteEngineRequestTests: XCTestCase {

    private static let defaultsKeys = ["remoteServerURL", "remoteServerModel",
                                       "remoteServerTimeoutEnabled", "remoteServerTimeoutSeconds"]
    private var savedDefaults: [String: Any] = [:]
    private var savedAPIKey: String?

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys {
            savedDefaults[key] = DefaultsStore.current.object(forKey: key)
        }
        savedAPIKey = AppPreferences.shared.remoteServerAPIKey
    }

    override func tearDown() {
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] {
                DefaultsStore.current.set(value, forKey: key)
            } else {
                DefaultsStore.current.removeObject(forKey: key)
            }
        }
        AppPreferences.shared.remoteServerAPIKey = savedAPIKey
        super.tearDown()
    }

    private func engine(url: String, model: String = "", apiKey: String? = nil,
                        timeoutEnabled: Bool = true, timeoutSeconds: Double = 60) async throws -> RemoteEngine {
        let prefs = AppPreferences.shared
        prefs.remoteServerURL = url
        prefs.remoteServerModel = model
        prefs.remoteServerAPIKey = apiKey
        prefs.remoteServerTimeoutEnabled = timeoutEnabled
        prefs.remoteServerTimeoutSeconds = timeoutSeconds
        let engine = RemoteEngine()
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

    /// What `transcribeAudio` sends for `settings`, with the boundary and audio fixed.
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
}
