import AppKit
import LiquidGlass
import SwiftUI

#if DEBUG && canImport(FoundationModels)

/// Plays the REAL indicator (IndicatorWindowManager, the user's theme and layout) through its whole
/// life over a stand-in desktop and screen-records it, for the GIFs in the pull request:
///
///   entrance + emerge → listening (moving waveform) → live caption → Stop (transcribing morph)
///   → "Copied" → hide, then a second take that is cancelled.
///
///   PROBE_GIF=<night|day|busy> [PROBE_LIVE=1] OpenSuperWhisper indicator-live <outDir>
///
/// Without PROBE_LIVE the take has no caption (most engines); with it the caption streams in.
///
/// Writes `<outDir>/capture.mov` plus `<outDir>/events.txt` (each event's time in seconds since
/// the recording started), which the caller cuts into scenes. The microphone and the transcription
/// engine are never used: the waveform and the caption are staged.
@available(macOS 26.0, *)
enum IndicatorGIFProbe {
    @MainActor
    static func run(styleName: String, outDir: String) -> Never {
        let style = WallpaperStyle(rawValue: styleName) ?? .night
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: style == .day ? .aqua : .darkAqua)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let screen = NSScreen.main!.frame
        let backdrop = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        // The bubble's centre at the "top" position: its bottom edge is 140pt below the top of the
        // screen and it is roughly 40pt tall.
        let focus = UnitPoint(x: 0.5, y: 120 / screen.height)
        backdrop.contentView = NSHostingView(rootView: DesktopWallpaper(style, focus: focus))
        backdrop.orderFrontRegardless()

        // The strip the bubble lives in at the "top" position (its bottom edge 140pt below the top
        // of the screen), wide enough for a live caption.
        let region = "\(Int(screen.midX - 330)),50,660,150"
        let duration = 15.0
        let capture = Process()
        capture.launchPath = "/usr/sbin/screencapture"
        capture.arguments = ["-x", "-v", "-V", "\(Int(duration))", "-R\(region)", "\(outDir)/capture.mov"]

        var events: [String] = []
        var startedAt = Date()
        func mark(_ name: String) {
            events.append(String(format: "%.2f %@", Date().timeIntervalSince(startedAt), name))
        }

        let manager = IndicatorWindowManager.shared
        var vm: IndicatorViewModel?

        // A voice-like waveform: every band breathing on its own, louder in the middle.
        var pumping = false
        let pump = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard pumping else { return }
                let t = Date().timeIntervalSinceReferenceDate
                let n = SpectrumBands.count
                let levels = (0..<n).map { i -> Float in
                    let centre = 1 - abs(Double(i) - Double(n - 1) / 2) / (Double(n) / 2)
                    let wave = (sin(t * 7 + Double(i) * 1.3) + sin(t * 3.1 + Double(i) * 0.7)) / 4 + 0.5
                    let envelope = (sin(t * 1.7) + 1) / 2 * 0.5 + 0.5
                    return Float(max(0.08, min(1, (0.25 + 0.75 * centre) * wave * envelope)))
                }
                SpectrumAnalyzer.shared.stageBands(levels)
            }
        }
        RunLoop.main.add(pump, forMode: .common)

        func take() {
            vm = manager.show(nearPoint: nil)
            vm?.state = .recording
            vm?.isBlinking = true
            pumping = true
        }

        let words = ["Liquid", "Glass", "bends", "whatever", "sits", "behind", "it,", "so",
                     "the", "bubble", "feels", "like", "part", "of", "the", "desktop."]
        var steps: [(Double, () -> Void)] = [
            (0.4, { try? capture.run(); startedAt = Date() }),
            (1.2, { mark("show"); take() }),
        ]
        // PROBE_LIVE: an engine that streams a live caption. Without it, the common case: the
        // bubble just listens (dot, label, waveform) and transcribes after Stop, so the take is
        // shorter and everything after it moves up.
        let live = ProcessInfo.processInfo.environment["PROBE_LIVE"] != nil
        let shift = live ? 0 : -2.6
        // The caption streams in word by word, the last two still volatile (dimmed).
        for k in 1...words.count where live {
            steps.append((3.0 + Double(k) * 0.16, {
                if k == 1 { mark("caption") }
                let settled = max(0, k - 2)
                StreamingTranscriptionController.shared.stageCaption(
                    confirmed: words[0..<settled].joined(separator: " "),
                    volatile: words[settled..<k].joined(separator: " "))
            }))
        }
        let after: [(Double, () -> Void)] = [
            (6.4, {
                mark("stop")
                pumping = false
                SpectrumAnalyzer.shared.stageBands(Array(repeating: 0, count: SpectrumBands.count))
                StreamingTranscriptionController.shared.stageCaption(confirmed: "", volatile: "")
                vm?.state = .decoding
            }),
            (7.9, { mark("copied"); vm?.state = .info("Copied — press ⌘V to paste") }),
            (9.3, { mark("hide"); manager.hide() }),
            (10.2, { mark("show2"); take() }),
            (11.6, { mark("cancel"); pumping = false; manager.stopForce() }),
            (13.8, {
                mark("end")
                try? events.joined(separator: "\n").write(toFile: "\(outDir)/events.txt",
                                                          atomically: true, encoding: .utf8)
                // screencapture writes the movie only when its -V time is up; leaving before
                // that orphaned it and the next capture started with no file yet.
                DispatchQueue.global().async {
                    capture.waitUntilExit()
                    exit(0)
                }
            }),
        ]
        steps += after.map { ($0.0 + shift, $0.1) }
        for (at, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { step() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
        NSApplication.shared.run()
        exit(0)
    }
}

#endif
