import XCTest

@testable import OpenSuperWhisper
@testable import WhisperCore

/// Onboarding is the only thing standing between a fresh install and a dictation that can't
/// work, so its exit condition is pinned here.
///
/// The app used to also try copying a bundled `ggml-tiny.en.bin` at launch. No such resource
/// was ever in the bundle, so the copy silently did nothing and `ensureDefaultModelPresent()`
/// guaranteed nothing despite its name (#54). Removing it is only safe because this gate is
/// real — hence the test.
@MainActor
final class OnboardingModelGateTests: XCTestCase {

    private func makeViewModel() -> OnboardingViewModel {
        let viewModel = OnboardingViewModel()
        viewModel.unifiedModels = [
            OnboardingUnifiedModel(name: "Whisper", isDownloaded: false, description: "",
                                   type: .whisper(url: URL(string: "https://example.invalid/m.bin")!,
                                                  size: 75)),
            OnboardingUnifiedModel(name: "Parakeet", isDownloaded: false, description: "",
                                   type: .parakeet(version: "v3")),
        ]
        return viewModel
    }

    func testCannotContinueWithNothingChosen() {
        XCTAssertFalse(makeViewModel().canContinue,
                       "a fresh install must not reach the app with no engine at all")
    }

    /// Selecting a model isn't enough — it has to be on disk. This is the case the deleted
    /// bundled-model code pretended to cover.
    func testCannotContinueWithAModelSelectedButNotDownloaded() {
        let viewModel = makeViewModel()
        viewModel.selectModel(viewModel.unifiedModels[0])
        XCTAssertFalse(viewModel.canContinue)
    }

    func testCanContinueOnceTheSelectedModelIsDownloaded() {
        let viewModel = makeViewModel()
        viewModel.selectModel(viewModel.unifiedModels[0])
        viewModel.unifiedModels[0].isDownloaded = true
        XCTAssertTrue(viewModel.canContinue)
    }

    /// A downloaded model that isn't the selected one doesn't unlock the gate either.
    func testAnotherDownloadedModelDoesNotCount() {
        let viewModel = makeViewModel()
        viewModel.selectModel(viewModel.unifiedModels[0])
        viewModel.unifiedModels[1].isDownloaded = true
        XCTAssertFalse(viewModel.canContinue)
    }

    /// A remote server needs no local model, so it passes with nothing downloaded.
    func testRemoteServerNeedsNoLocalModel() {
        let viewModel = makeViewModel()
        viewModel.selectRemote()
        XCTAssertTrue(viewModel.canContinue)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, "remote")
    }
}
