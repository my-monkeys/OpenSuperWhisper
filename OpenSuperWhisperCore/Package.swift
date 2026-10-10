// swift-tools-version: 6.0
import PackageDescription

// OpenSuperWhisperCore: the transcription core shared by the macOS app and the iPhone app
// (docs/core-extraction.md). A static library, so GRDB, FluidAudio and ggml each exist once per
// process. Swift 5 mode with no upcoming features, because the app compiles that way and moving
// code here must not change isolation or async semantics.
//
// The two binary targets are built by Scripts/build-native.sh, which run.sh calls before
// resolving packages. A fresh clone runs `./run.sh build` (or the script) before opening Xcode,
// otherwise package resolution fails on the missing xcframeworks.
let package = Package(
    name: "OpenSuperWhisperCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OpenSuperWhisperCore", type: .static,
                 targets: ["OpenSuperWhisperCore", "OSWSenseVoice"]),
    ],
    dependencies: [
        // Same URL and requirement as the app's project, so the workspace resolves one checkout
        // and run.sh keeps patching it.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .binaryTarget(name: "OSWNative", path: "Binaries/OSWNative.xcframework"),
        // macOS only: the vendored sherpa-onnx library has no iOS slice.
        .binaryTarget(name: "SherpaOnnx", path: "Binaries/SherpaOnnx.xcframework"),
        // SenseVoice through sherpa-onnx. Its sources compile to nothing outside Apple Silicon
        // Macs, because onnxruntime, which sherpa needs, ships for arm64 macOS only.
        .target(
            name: "OSWSenseVoice",
            dependencies: [
                .target(name: "SherpaOnnx", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "OpenSuperWhisperCore",
            dependencies: ["OSWNative", "OSWSenseVoice",
                           .product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
