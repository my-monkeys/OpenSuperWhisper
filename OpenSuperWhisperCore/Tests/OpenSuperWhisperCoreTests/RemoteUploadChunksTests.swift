import XCTest
@testable import OpenSuperWhisperCore

/// Files over a server's upload cap are cut at pauses and sent in parts. The planner and the WAV
/// encoder are pure; the last test runs the real engine against a stub server.
final class RemoteUploadChunksTests: CoreTestCase {

    private func noise(_ count: Int) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? 0.5 : -0.5 }
    }

    func testOneRangeWhenEverythingFits() {
        let samples = noise(1000)
        XCTAssertEqual(RemoteUploadChunks.plan(samples: samples, maxSamples: 1000), [0..<1000])
        XCTAssertEqual(RemoteUploadChunks.plan(samples: samples, maxSamples: 5000), [0..<1000])
        XCTAssertEqual(RemoteUploadChunks.plan(samples: [], maxSamples: 1000), [0..<0])
    }

    func testRangesCoverEverySampleContiguouslyWithinTheMax() {
        let samples = noise(100_000)
        let max = 16_000
        let ranges = RemoteUploadChunks.plan(samples: samples, maxSamples: max)
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound)
        }
        for range in ranges {
            XCTAssertFalse(range.isEmpty)
            XCTAssertLessThanOrEqual(range.count, max)
        }
    }

    func testCutLandsInASilentGapBeforeTheLimit() {
        var samples = noise(50_000)
        let gap = 11_000..<14_000
        for index in gap { samples[index] = 0 }
        let ranges = RemoteUploadChunks.plan(samples: samples, maxSamples: 16_000)
        let cut = ranges[0].upperBound
        XCTAssertTrue(gap.contains(cut), "cut at \(cut) is not inside the silent gap")
    }

    func testMaxSamplesFromBytesAccountsForTheHeader() {
        XCTAssertEqual(RemoteUploadChunks.maxSamples(forBytes: 1044), 500)
        let samples = noise(10)
        XCTAssertEqual(RemoteUploadChunks.wavData(samples: samples[...]).count, 44 + 20)
    }

    func testWavHeaderAndLength() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1]
        let data = RemoteUploadChunks.wavData(samples: samples[...])
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        func string(_ range: Range<Int>) -> String { String(decoding: data[range], as: UTF8.self) }
        func int(_ offset: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        XCTAssertEqual(string(0..<4), "RIFF")
        XCTAssertEqual(int(4, 4), 36 + 8)
        XCTAssertEqual(string(8..<16), "WAVEfmt ")
        XCTAssertEqual(int(16, 4), 16)
        XCTAssertEqual(int(20, 2), 1)
        XCTAssertEqual(int(22, 2), 1)
        XCTAssertEqual(int(24, 4), 16_000)
        XCTAssertEqual(int(28, 4), 32_000)
        XCTAssertEqual(int(32, 2), 2)
        XCTAssertEqual(int(34, 2), 16)
        XCTAssertEqual(string(36..<40), "data")
        XCTAssertEqual(int(40, 4), 8)
        XCTAssertEqual(Int16(truncatingIfNeeded: int(44, 2)), 0)
        XCTAssertEqual(Int16(truncatingIfNeeded: int(48, 2)), -16383)
    }

    func testSamplesAreClamped() {
        let data = RemoteUploadChunks.wavData(samples: [3.0, -3.0][...])
        let values = (0..<2).map { Int16(truncatingIfNeeded: Int(data[44 + $0 * 2]) | Int(data[45 + $0 * 2]) << 8) }
        XCTAssertEqual(values, [Int16.max, -Int16.max])
    }

    func testPartFilename() {
        XCTAssertEqual(RemoteUploadChunks.partFilename(original: "meeting.m4a", index: 0), "meeting-part1.wav")
        XCTAssertEqual(RemoteUploadChunks.partFilename(original: "a.b.wav", index: 2), "a.b-part3.wav")
    }

    // MARK: Engine

    /// A file over the limit goes up in several requests, named by part, and the texts come back
    /// joined in order. The limit is shrunk so a one-second clip needs three parts.
    func testOversizedFileIsSentInPartsAndJoinedInOrder() async throws {
        let prefs = CoreTestEnvironment.preferences
        prefs.remoteServerURL = "https://api.example.test/v1"
        prefs.remoteServerModel = "m"
        prefs.remoteServerAPIKey = nil
        let samples = noise(16_000)
        let wav = try Fixtures.writeWhisperWav(samples, name: "long")
        defer { try? FileManager.default.removeItem(at: wav) }

        let limit = 44 + 2 * 7_000
        StubServer.reset(responses: [(200, #"{"text":" one "}"#), (200, #"{"text":"two"}"#),
                                     (200, #"{"text":""}"#), (200, #"{"text":"three"}"#)])
        let engine = RemoteEngine(sessionConfiguration: StubServer.configuration, maxUploadBytes: limit)
        try await engine.initialize()

        let text = try await engine.transcribeAudio(url: wav, settings: Fixtures.pinnedSettings())

        let sent = StubServer.requests
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(text, "one two")
        let bodies = sent.map { String(decoding: $0.body, as: UTF8.self) }
        let baseName = wav.deletingPathExtension().lastPathComponent
        for (index, body) in bodies.enumerated() {
            XCTAssertTrue(body.contains("filename=\"\(baseName)-part\(index + 1).wav\""), "part \(index + 1)")
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nm\r\n"))
        }
        for request in sent { XCTAssertLessThanOrEqual(request.body.count, limit + 600) }
    }
}

/// A server that answers from a queue and records what reached it. URLProtocol only sees a body
/// stream, never `httpBody`, so the stream is read out.
private final class StubServer: URLProtocol {
    struct Received { let body: Data }

    private static let lock = NSLock()
    private static var responses: [(status: Int, body: String)] = []
    private static var received: [Received] = []

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [StubServer.self]
        return config
    }

    static func reset(responses: [(Int, String)]) {
        lock.withLock {
            self.responses = responses.map { (status: $0.0, body: $0.1) }
            received = []
        }
    }

    static var requests: [Received] { lock.withLock { received } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Received(body: Self.readBody(of: request))
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
