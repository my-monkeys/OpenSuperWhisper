import XCTest
@testable import OpenSuperWhisperCore

/// The built-in model on a long dictation: the reply runs to the end, and a reply that cannot is
/// reported as cut. Reads the model only from `OSW_TEST_GGUF` (`TEST_RUNNER_OSW_TEST_GGUF` through
/// xcodebuild) and skips without it, so CI never runs these.
final class CoreLlamaCompletionTests: CoreTestCase {

    /// About four minutes of speech, roughly 800 tokens: past the 512 that used to cap the reply.
    private static let longDictation = """
        okay so um this is the weekly update for the mobile team and I want to go through what \
        happened since last Monday because a lot moved and I think some of it got lost in the chat. \
        first the release. we shipped version four point two on Wednesday afternoon, a day later \
        than planned, because the payment screen crashed on older iPads when you rotated it during \
        checkout. Julia found it in the last smoke test, which honestly saved us, and the fix was \
        small, it was a layout constraint that fought with the keyboard. so the release went out \
        Wednesday and the crash rate since then is the lowest we have had this year, which is nice \
        to see after the mess in the spring. second, the onboarding experiment. we ran the shorter \
        onboarding for half of new users for two weeks. the short version has three screens instead \
        of seven, and the completion rate went up from sixty one percent to seventy eight percent, \
        but and this is the important part, the people who went through the short version were less \
        likely to turn on notifications, about twelve points less. so we need to decide whether we \
        keep the short flow and ask for notifications later, maybe after the first saved item, or \
        whether we go back. my suggestion is to keep the short flow and add the notification prompt \
        after the first save, and test that for another two weeks. third, hiring. we had four \
        interviews for the senior Android role. two of them were good, one was really strong, she \
        has worked on offline sync before which is exactly the thing we keep struggling with. we \
        are doing the final round with her on Friday and I would love for at least two of you to \
        join, it is at ten thirty. fourth, the backend migration. the API team moved the search \
        endpoint to the new cluster on Tuesday night and we saw latency go down by almost half on \
        the search screen, but the image uploads got slower, around two seconds more on average, \
        and nobody knows why yet. Marco is looking at it with them and thinks it might be the new \
        load balancer doing something weird with large request bodies. if that is the case it \
        should be a config change and not a code change, so fingers crossed. fifth, the design \
        review for the new settings page. we looked at the three proposals and everyone liked the \
        second one, the one with the grouped sections and the search field on top. there were some \
        concerns about how the dark mode looked, the contrast on the secondary labels was too low, \
        so design is going to adjust that and send a new version on Monday. sixth, a few small \
        things. the test devices in the office need updating, half of them are still on an old \
        system version. the shared calendar for on call is out of date, please check your weeks. \
        and the team lunch is moving from Thursday to the following Tuesday because half of us \
        will be at the conference. last thing, and then I will stop talking. I know the last month \
        was heavy with the release and the crash and the migration all at once, and I really \
        appreciate how everyone stepped up. let us try to keep next week calmer, no new big things \
        until the onboarding test is done. and please, if you are blocked on anything, say it in \
        the stand up instead of waiting, that is all from me, see you all on Monday at the pelican \
        meeting room.
        """

    func testALongDictationIsCleanedToTheEnd() throws {
        let context = try XCTUnwrap(LlamaContext(modelPath: try requireModel().path))
        let completion = context.generate(system: LLMPostProcessor.defaultInstruction, user: Self.longDictation)
        XCTAssertEqual(completion.stop, .finished)
        XCTAssertTrue(completion.text.localizedCaseInsensitiveContains("pelican"),
                      "the reply lost the end of the dictation:\n\(completion.text.suffix(300))")
    }

    /// The flat budget the backend used to apply: the reply is now reported as cut, not returned
    /// as if it were whole.
    func testTheOldFlatBudgetIsReportedAsCut() throws {
        let context = try XCTUnwrap(LlamaContext(modelPath: try requireModel().path))
        let completion = context.generate(system: LLMPostProcessor.defaultInstruction, user: Self.longDictation,
                                          maxTokens: 512)
        XCTAssertEqual(completion.stop, .tokenBudget)
    }

    /// Trimming the prompt's head used to drop the instructions and keep the dictation's tail.
    func testAPromptThatDoesNotFitIsRefusedNotTrimmed() throws {
        let context = try XCTUnwrap(LlamaContext(modelPath: try requireModel().path, contextLength: 256))
        let completion = context.generate(system: LLMPostProcessor.defaultInstruction, user: Self.longDictation)
        XCTAssertEqual(completion, LlamaContext.Completion(text: "", stop: .promptTooLong))
    }

    private func requireModel() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty else {
            throw XCTSkip("OSW_TEST_GGUF is not set")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("OSW_TEST_GGUF does not name a readable file: \(path)")
        }
        return URL(fileURLWithPath: path)
    }
}
