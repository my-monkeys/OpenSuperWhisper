// swift-tools-version: 6.0
import PackageDescription

// LiquidGlass — the app's Liquid Glass UI component library (macOS 26 / Tahoe).
//
// It is a standalone Swift package with ZERO native dependencies, so its SwiftUI previews render
// real `glassEffect` in Xcode's Canvas (the main app can't preview — its native C/C++ libs break
// the preview JIT executor). The OpenSuperWhisper app links this package and renders these glass
// components in its Liquid Glass theme; the app's legacy (pre-Tahoe) look stays in the app.
//
// A KNOWN platform version (`.macOS(.v14)`) so Xcode populates the scheme's supported platforms and
// the Canvas gets a run destination; the macOS-26-only glass APIs are guarded with
// `@available(macOS 26.0, *)` in the sources.
let package = Package(
    name: "LiquidGlass",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiquidGlass", targets: ["LiquidGlass"]),
    ],
    targets: [
        .target(name: "LiquidGlass"),
    ]
)
