#if os(macOS) && arch(arm64)
internal import sherpa_onnx

/// The SenseVoice recognizer, configured the way the app's engine uses it. A thin layer over
/// sherpa-onnx's Swift API so no sherpa C type appears in this module's public interface.
public final class SenseVoiceRecognizer {
    private let recognizer: SherpaOnnxOfflineRecognizer

    public init(modelPath: String, tokensPath: String) {
        let svConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "",                     // "" = auto-detect among zh/en/ja/ko/yue
            useInverseTextNormalization: true // punctuation + digits
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            senseVoice: svConfig
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// The recognized text of `samples`, which must be mono at `sampleRate`.
    public func decode(samples: [Float], sampleRate: Int) -> String {
        recognizer.decode(samples: samples, sampleRate: sampleRate).text
    }
}
#endif
