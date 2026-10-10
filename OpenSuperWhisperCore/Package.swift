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
        .library(name: "OpenSuperWhisperCore", type: .static, targets: ["OpenSuperWhisperCore"]),
    ],
    targets: [
        .binaryTarget(name: "OSWNative", path: "Binaries/OSWNative.xcframework"),
        // macOS only: the vendored sherpa-onnx library has no iOS slice.
        .binaryTarget(name: "SherpaOnnx", path: "Binaries/SherpaOnnx.xcframework"),
        .target(
            name: "OpenSuperWhisperCore",
            dependencies: [
                "OSWNative",
                .target(name: "SherpaOnnx", condition: .when(platforms: [.macOS])),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
