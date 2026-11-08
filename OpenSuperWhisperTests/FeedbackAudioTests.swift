import XCTest

@testable import OpenSuperWhisper

/// Records what would have been posted and answers from a canned status. Never the real endpoint:
/// every request lands in the owner's inbox.
private final class RecordingTransport {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let status: Int

    init(status: Int = 201) { self.status = status }

    var requests: [URLRequest] { lock.withLock { sent } }

    func sender(loadAudio: @escaping (DictationAudioChoice) async throws -> FeedbackAttachment = { _ in
        FeedbackAttachment(filename: "dictation-x.wav", contentType: "audio/wav", data: Data("RIFFdata".utf8))
    }) -> FeedbackSender {
        FeedbackSender(transport: { [self] request in
            lock.withLock { sent.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (Data(), response)
        }, loadAudio: loadAudio)
    }
}

private func choice(size: Int? = 1_000_000, duration: TimeInterval = 20,
                    url: URL = URL(fileURLWithPath: "/nonexistent/a.wav")) -> DictationAudioChoice {
    DictationAudioChoice(id: UUID(), timestamp: Date(), preview: "hello there", duration: duration,
                         fileURL: url, fileSize: size)
}

final class MultipartFormTests: XCTestCase {

    func testBodyCarriesEachFieldThenTheFileWithCRLFAndTheClosingBoundary() throws {
        var form = MultipartForm()
        form.boundary = "BOUND"
        form.fields = [("message", "It broke"), ("product", "opensuperwhisper")]
        form.files = [.init(name: "files", filename: "dictation-1.wav", contentType: "audio/wav",
                            data: Data([0, 1, 2, 255]))]

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUND")
        var expected = Data("--BOUND\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nIt broke\r\n".utf8)
        expected.append(Data("--BOUND\r\nContent-Disposition: form-data; name=\"product\"\r\n\r\nopensuperwhisper\r\n".utf8))
        expected.append(Data(("--BOUND\r\nContent-Disposition: form-data; name=\"files\"; "
                              + "filename=\"dictation-1.wav\"\r\nContent-Type: audio/wav\r\n\r\n").utf8))
        expected.append(Data([0, 1, 2, 255]))
        expected.append(Data("\r\n--BOUND--\r\n".utf8))
        XCTAssertEqual(form.body, expected)
    }

    func testEachFormGetsItsOwnBoundary() {
        XCTAssertNotEqual(MultipartForm().boundary, MultipartForm().boundary)
    }
}

final class FeedbackRequestTests: XCTestCase {
    private let submission = FeedbackSubmission(kind: .bug, message: " It broke ", email: "a@b.co",
                                                details: "OpenSuperWhisper 1.0 (1)")
    private let attachment = FeedbackAttachment(filename: "dictation-7.wav", contentType: "audio/wav",
                                                data: Data("RIFF-bytes".utf8))

    func testWithoutAFileTheRequestStaysJSONWithTheShortTimeout() throws {
        let request = try FeedbackSender.request(for: submission)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, FeedbackSender.timeout)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(json, ["message": "It broke", "email": "a@b.co", "product": "opensuperwhisper",
                              "context": "app · bug · OpenSuperWhisper 1.0 (1)"])
    }

    func testWithAFileTheSameFieldsGoAsMultipartAndTheTimeoutIsLonger() throws {
        let request = try FeedbackSender.request(for: submission, attachment: attachment)
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        XCTAssertEqual(request.timeoutInterval, FeedbackSender.uploadTimeout)
        XCTAssertGreaterThan(FeedbackSender.uploadTimeout, FeedbackSender.timeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), FeedbackSender.userAgent)
        XCTAssertFalse(request.httpShouldHandleCookies)

        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        for (name, value) in [("message", "It broke"), ("email", "a@b.co"), ("product", "opensuperwhisper"),
                              ("context", "app · bug · OpenSuperWhisper 1.0 (1)")] {
            XCTAssertTrue(text.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"), name)
        }
        XCTAssertTrue(text.contains("name=\"files\"; filename=\"dictation-7.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF-bytes\r\n--\(boundary)--\r\n"))
    }

    func testAnEmptyEmailIsLeftOutOfTheMultipartToo() throws {
        var bare = submission
        bare.email = " "
        let body = try XCTUnwrap(FeedbackSender.request(for: bare, attachment: attachment).httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("name=\"email\""))
    }

    func testSendingLoadsTheAudioAndPostsItOnce() async throws {
        let transport = RecordingTransport()
        var withAudio = submission
        withAudio.audio = choice()
        try await transport.sender().send(withAudio)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(transport.requests[0].value(forHTTPHeaderField: "Content-Type")).hasPrefix("multipart/"))
    }

    func testAnUnreadableRecordingSendsNothing() async {
        let transport = RecordingTransport()
        var withAudio = submission
        withAudio.audio = choice()
        let sender = transport.sender(loadAudio: { _ in throw DictationAudioLoader.Failure.unreadable })
        do {
            try await sender.send(withAudio)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FeedbackSendError, .audioUnavailable)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

final class DictationAudioPolicyTests: XCTestCase {

    func testEligibilityFollowsTheFileSizeAgainstTheLimit() {
        XCTAssertEqual(DictationAudioPolicy.eligibility(fileSize: nil), .noAudio)
        XCTAssertEqual(DictationAudioPolicy.eligibility(fileSize: 0), .eligible)
        XCTAssertEqual(DictationAudioPolicy.eligibility(fileSize: 25_000_000), .eligible)
        XCTAssertEqual(DictationAudioPolicy.eligibility(fileSize: 25_000_001), .tooLarge)
    }

    func testTheContentTypeFollowsTheExtension() {
        XCTAssertEqual(DictationAudioPolicy.contentType(forExtension: "wav"), "audio/wav")
        XCTAssertEqual(DictationAudioPolicy.contentType(forExtension: "M4A"), "audio/mp4")
        XCTAssertEqual(DictationAudioPolicy.contentType(forExtension: "xyz"), "application/octet-stream")
    }

    func testThePreviewKeepsTheFirstWords() {
        XCTAssertEqual(DictationAudioChoice.firstWords(of: "  one two\nthree  "), "one two three")
        XCTAssertEqual(DictationAudioChoice.firstWords(of: "a b c d e f g h i j"), "a b c d e f g h…")
        XCTAssertEqual(DictationAudioChoice.firstWords(of: ""), "")
    }

    func testOnlyAnEligibleChoiceCanBeAttached() {
        XCTAssertTrue(choice(size: 5).isAttachable)
        XCTAssertFalse(choice(size: nil).isAttachable)
        XCTAssertFalse(choice(size: 30_000_000).isAttachable)
    }
}

final class DictationAudioLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheStoredBytesGoOutUntouchedUnderTheirOwnExtension() async throws {
        let url = directory.appendingPathComponent("1.wav")
        let bytes = Data((0..<2048).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        let audio = choice(url: url)

        let attachment = try await DictationAudioLoader.load(audio)
        XCTAssertEqual(attachment.data, bytes)
        XCTAssertEqual(attachment.contentType, "audio/wav")
        XCTAssertEqual(attachment.filename, "dictation-\(audio.id.uuidString).wav")
    }

    func testAFileThatGrewPastTheLimitIsRefusedAtSendTime() async throws {
        let url = directory.appendingPathComponent("big.wav")
        try Data(count: DictationAudioPolicy.maxUploadBytes + 1).write(to: url)
        do {
            _ = try await DictationAudioLoader.load(choice(size: 1_000, url: url))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? DictationAudioLoader.Failure, .tooLarge)
        }
    }

    func testAMissingFileIsUnreadable() async {
        do {
            _ = try await DictationAudioLoader.load(choice(url: directory.appendingPathComponent("gone.wav")))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DictationAudioLoader.Failure, .unreadable)
        }
    }
}

@MainActor
final class FeedbackFormAudioTests: XCTestCase {
    private var sentCount = 0

    private func makeModel(_ transport: RecordingTransport,
                           loadAudio: (@Sendable (DictationAudioChoice) async throws -> FeedbackAttachment)? = nil,
                           recent: [DictationAudioChoice] = []) -> FeedbackFormModel {
        FeedbackFormModel(sender: loadAudio.map { transport.sender(loadAudio: $0) } ?? transport.sender(),
                          appDetails: { "details" },
                          recentDictations: { recent },
                          onSent: { [self] in sentCount += 1 })
    }

    func testNothingIsAttachedByDefaultAndTheLineSaysTextOnly() {
        let model = makeModel(RecordingTransport())
        XCTAssertNil(model.attachedAudio)
        XCTAssertNil(model.submission.audio)
        XCTAssertEqual(model.disclosure, .textOnly)
    }

    func testAttachingSwitchesTheLineAndRemovingSwitchesItBack() {
        let model = makeModel(RecordingTransport())
        model.isPickingAudio = true
        let audio = choice()
        model.attach(audio)
        XCTAssertEqual(model.attachedAudio, audio)
        XCTAssertEqual(model.submission.audio, audio)
        XCTAssertEqual(model.disclosure, .withRecording)
        XCTAssertFalse(model.isPickingAudio)

        model.detachAudio()
        XCTAssertNil(model.attachedAudio)
        XCTAssertEqual(model.disclosure, .textOnly)
    }

    func testAnUnattachableDictationIsIgnored() {
        let model = makeModel(RecordingTransport())
        model.attach(choice(size: nil))
        model.attach(choice(size: 50_000_000))
        XCTAssertNil(model.attachedAudio)
    }

    func testTheRecentDictationsComeFromTheProvider() async {
        let recent = [choice(), choice(size: nil)]
        let model = makeModel(RecordingTransport(), recent: recent)
        await model.refreshRecentDictations()
        XCTAssertEqual(model.recentDictations, recent)
    }

    func testASuccessfulSendSendsTheFileAndClearsTheAttachment() async throws {
        let transport = RecordingTransport()
        let model = makeModel(transport)
        model.message = "It crashed"
        model.attach(choice())
        await model.send()

        XCTAssertEqual(model.status, .sent)
        XCTAssertNil(model.attachedAudio)
        XCTAssertEqual(sentCount, 1)
        let body = String(decoding: try XCTUnwrap(transport.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"files\""))
    }

    func testAFailedSendKeepsTheAttachmentForTheRetry() async {
        let model = makeModel(RecordingTransport(status: 500))
        model.message = "It crashed"
        model.attach(choice())
        await model.send()
        XCTAssertEqual(model.status, .failed)
        XCTAssertNotNil(model.attachedAudio)
    }

    func testTooBigOrTooManyBytesWithAFileIsAnAudioProblemNotAMessageOne() async {
        for code in [413, 429] {
            let model = makeModel(RecordingTransport(status: code))
            model.message = "It crashed"
            model.attach(choice())
            await model.send()
            XCTAssertEqual(model.status, .audioFailed, "\(code)")
            XCTAssertNotNil(model.attachedAudio)
        }
        let model = makeModel(RecordingTransport(status: 413))
        model.message = "It crashed"
        await model.send()
        XCTAssertEqual(model.status, .refused)
    }

    func testAnUnreadableRecordingIsAnAudioProblem() async {
        let transport = RecordingTransport()
        let model = makeModel(transport, loadAudio: { _ in throw DictationAudioLoader.Failure.unreadable })
        model.message = "It crashed"
        model.attach(choice())
        await model.send()
        XCTAssertEqual(model.status, .audioFailed)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCancelDropsTheAttachmentButClosingTheCardKeepsIt() {
        let model = makeModel(RecordingTransport())
        model.attach(choice())
        model.cardClosed()
        XCTAssertNotNil(model.attachedAudio)
        model.discard()
        XCTAssertNil(model.attachedAudio)
    }
}
