import AppKit
import SwiftUI

// Liquid Glass only exists in the macOS 26 SDK. `@available` guards the runtime, not
// compilation — older toolchains would still parse these calls and fail. Keyed off
// FoundationModels like the Apple Speech engine, so older SDKs build a stub that renders
// nothing rather than failing the build.
#if canImport(FoundationModels)

struct Sample {
    let name: String
    let caption: String
    let volatile: String
    let showButtons: Bool
    let glass: GlassKind
}


enum GlassKind: String, CaseIterable {
    case regular          // what the bubble ships with today
    case clear            // the more transparent variant macOS offers
    case clearTinted      // clear + a dark tint for legibility over bright backdrops
    case regularTinted    // regular + dark tint

    /// Nil on macOS 14/15: there is no glass to render, the gallery simply skips the sample
    /// rather than failing the whole run.
    @available(macOS 26.0, *)
    var glass: Glass? {
        guard #available(macOS 26.0, *) else { return nil }
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        case .clearTinted: return .clear.tint(.black.opacity(0.35))
        case .regularTinted: return .regular.tint(.black.opacity(0.30))
        }
    }
}

/// Renders the recording bubble in isolation (no app, no window manager) straight to PNG files,
/// so the Liquid Glass look can be iterated on without launching OpenSuperWhisper.
///
///   OpenSuperWhisper gallery <output-dir>
///
/// Reached from the app's entry point (`CLI.shouldHandle`), runs headless via `ImageRenderer`.
/// Every variant is rendered on a dark *and* a light backdrop, because glass reads differently
/// against each, plus a couple of glass API variants to compare side by side.
@available(macOS 26.0, *)
@ViewBuilder
func capsule(_ sample: Sample, rim: Bool) -> some View {
    let shape = AnyShape(Capsule())
    HStack(spacing: 10) {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(.red)
            .frame(width: 16)
        if sample.showButtons {
            Image(systemName: "stop.circle")
                .font(.system(size: 19))
                .foregroundStyle(.red)
        }
        Text("Recording…")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 7)
    .frame(minHeight: 36)
    .background {
        if let glass = sample.glass.glass {
            Color.clear
                .glassEffect(glass, in: shape)
                .overlay {
                    if rim {
                        shape.stroke(
                            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    }
                }
        } else {
            shape.fill(Material.thinMaterial)
        }
    }
    .fixedSize()
}

@available(macOS 26.0, *)
@ViewBuilder
func captionCapsule(_ sample: Sample, rim: Bool) -> some View {
    let shape = AnyShape(Capsule())
    HStack(spacing: 10) {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(.red)
            .frame(width: 16)
        (Text("hello ") + Text("world this is a ").foregroundColor(.secondary) + Text("dictation"))
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300, alignment: .leading)
        if sample.showButtons {
            Image(systemName: "stop.circle")
                .font(.system(size: 19))
                .foregroundStyle(.red)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 7)
    .frame(minHeight: 36)
    .background {
        if let glass = sample.glass.glass {
            Color.clear
                .glassEffect(glass, in: shape)
                .overlay {
                    if rim {
                        shape.stroke(
                            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    }
                }
        } else {
            shape.fill(Material.thinMaterial)
        }
    }
    .fixedSize()
}

@available(macOS 26.0, *)
@ViewBuilder
func card(_ sample: Sample) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
            Text("Transcription")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.red)
        }
        Text("hello world this is a longer dictation that wraps onto a second line")
            .font(.system(size: 14))
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 340)
    .background {
        if let glass = sample.glass.glass {
            RoundedRectangle(cornerRadius: 20)
                .fill(.clear)
                .glassEffect(glass, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20).stroke(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 20).fill(Material.thinMaterial)
        }
    }
    .fixedSize()
}

enum BubbleGallery {

    /// A backdrop the bubble is shown against. Glass samples what is behind it, so the same
    /// bubble reads differently on each.
    enum Backdrop: String, CaseIterable {
        case darkDesktop = "dark-desktop"
        case lightDesktop = "light-desktop"
        case busyDesktop = "busy-desktop"

        var color: Color {
            switch self {
            case .darkDesktop: return Color(red: 0.11, green: 0.11, blue: 0.13)
            case .lightDesktop: return Color(red: 0.92, green: 0.93, blue: 0.95)
            case .busyDesktop: return Color(red: 0.35, green: 0.55, blue: 0.42)
            }
        }
    }

    // MARK: - Stand-in state

    /// The gallery cannot touch `IndicatorViewModel` (its init wires singletons: the recorder,
    /// the store, the pipeline). The bubble's view model is only read through this protocol-ish
    /// surface, so the gallery renders with a light-weight fake.
    ///
    /// But `IndicatorWindow` takes the concrete class, so instead of faking it the gallery
    /// renders *surfaces* — the thing being designed — rather than the whole live view.

    // MARK: - Rendering

    /// One capsule with the given glass, sized like the real bubble (36pt tall, dot + label).

    /// A live-caption capsule, the state the bubble spends most of its life in.

    /// A card-sized surface, to see how each glass variant reads on a bigger box (like the
    /// Finder search field versus a larger popover). Lives at file scope now so the preview
    /// catalog can use it too.

    // MARK: - Entry

    @MainActor
    static func run(outputDir: String) -> Never {
        guard #available(macOS 26.0, *) else {
            FileHandle.standardOutput.write(Data("gallery: needs macOS 26+\n".utf8))
            exit(1)
        }
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        NSApplication.shared.setActivationPolicy(.prohibited)

        let samples: [Sample] = [
            Sample(name: "regular", caption: "", volatile: "", showButtons: false, glass: .regular),
            Sample(name: "clear", caption: "", volatile: "", showButtons: false, glass: .clear),
            Sample(name: "clear-tinted", caption: "", volatile: "", showButtons: false, glass: .clearTinted),
            Sample(name: "regular-tinted", caption: "", volatile: "", showButtons: false, glass: .regularTinted),
        ]

        let backdrops = Backdrop.allCases

        var rendered = 0
        for backdrop in backdrops {
            for sample in samples {
                // Pill (dot + label) and caption (dot + live text + stop) states.
                let views: [(String, AnyView)] = [
                    ("pill", AnyView(capsule(sample, rim: true))),
                    ("caption", AnyView(captionCapsule(sample, rim: true))),
                ]
                for (label, view) in views {
                    let name = "\(backdrop.rawValue)-\(sample.name)-\(label).png"
                    if render(view, to: dir.appendingPathComponent(name), backdrop: backdrop) {
                        rendered += 1
                    }
                }
                // Card, one per glass kind, to compare the larger surface.
                let cardName = "\(backdrop.rawValue)-card-\(sample.name).png"
                if render(AnyView(card(sample)), to: dir.appendingPathComponent(cardName), backdrop: backdrop) {
                    rendered += 1
                }
            }
        }

        FileHandle.standardOutput.write(Data("gallery: \(rendered) PNGs → \(dir.path)\n".utf8))
        exit(0)
    }

    @MainActor
    private static func render(_ view: AnyView, to url: URL, backdrop: Backdrop) -> Bool {
        let wrapped = ZStack {
            Rectangle().fill(backdrop.color)
            // A couple of shapes so the glass has something real to sample, like a desktop does.
            VStack(spacing: 40) {
                Circle().fill(.white.opacity(0.10)).frame(width: 120, height: 120)
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)).frame(width: 260, height: 60)
            }
            view
        }
        .frame(width: 520, height: 220)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 520, height: 220)
        // Glass samples the desktop through the window; ImageRenderer has no window, so the
        // effect is approximated by what the simulator draws. Good enough to compare variants.
        guard let image = renderer.nsImage else { return false }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: url)
        return true
    }
}

/// The live counterpart of the gallery: shows the capsule variants on the REAL desktop in a
/// borderless transparent panel, so the glass samples actual screen content the way the bubble
/// will. The headless gallery above cannot do that — ImageRenderer has no window server access.
///
///   OpenSuperWhisper gallery-live [seconds]
///
/// Prints the panel frame in top-left screen coordinates (what `screencapture -R` wants) and
/// exits after the delay, so a screenshot loop can capture the panel without the full app ever
/// launching: no menu-bar item, no dock icon, no recorder, no pipeline.
@available(macOS 26.0, *)
enum BubbleProbe {
    @MainActor
    static func run(seconds: Double) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)

        let panel = NSPanel(
            contentRect: NSRect(x: 640, y: 420, width: 720, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let content = VStack(alignment: .leading, spacing: 22) {
            ForEach(GlassKind.allCases, id: \.rawValue) { kind in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        capsule(Sample(name: kind.rawValue, caption: "", volatile: "",
                                       showButtons: false, glass: kind), rim: true)
                        // The native-in-glass samples: macOS's own glass button style inside the
                        // same surface family, for the on-bubble Stop/Cancel controls.
                        HStack(spacing: 8) {
                            Button {} label: {
                                Image(systemName: "stop.circle").font(.system(size: 17))
                            }
                            .buttonStyle(.glass)
                            Button {} label: {
                                Image(systemName: "trash").font(.system(size: 15))
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    Text(kind.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            captionCapsule(Sample(name: "clear", caption: "", volatile: "",
                                  showButtons: true, glass: .clear), rim: true)
        }
        .padding(28)
        // Labels need to read against the desktop; the capsules themselves carry the glass.
        .environment(\.colorScheme, .dark)

        panel.contentView = NSHostingView(rootView: content)
        panel.orderFrontRegardless()

        // Tell the caller where to point `screencapture -R` (top-left origin, points).
        DispatchQueue.main.async {
            if let screen = panel.screen ?? NSScreen.main {
                let frame = panel.frame
                let topLeftY = screen.frame.maxY - frame.maxY
                let line = "probe-frame: \(Int(frame.minX)),\(Int(topLeftY)),\(Int(frame.width)),\(Int(frame.height + 30))\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }

        // Keep it up long enough for a screenshot, then go away.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            panel.orderOut(nil)
            exit(0)
        }
        // Watchdog: never let the probe outlive its welcome even if something above misfires.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 10) { exit(1) }

        NSApplication.shared.run()
        exit(0)
    }
}

/// Drives the REAL indicator (IndicatorWindowManager, the user's theme and layout) through
/// recording → decoding over a vivid stand-in desktop and screenshots each step into `outDir`,
/// so the app's bubble can be checked against the Canvas without a human recording.
///
///   OpenSuperWhisper indicator-live <outDir>
enum IndicatorProbe {
    @MainActor
    static func run(outDir: String) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // A busy backdrop, below the indicator's .screenSaver level, so the glass has something
        // to refract (over a flat desktop clear glass reads as a plain grey pill).
        let screen = NSScreen.main!.frame
        let backdrop = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [.purple, .orange, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 40) {
                ForEach(0..<40) { i in Rectangle().fill(i % 2 == 0 ? Color.white : Color.black).frame(width: 18) }
            }
        })
        // PROBE_PLAIN=1 skips the backdrop: the bubble over the real desktop, as the user sees it.
        if ProcessInfo.processInfo.environment["PROBE_PLAIN"] == nil { backdrop.orderFrontRegardless() }

        let manager = IndicatorWindowManager.shared
        var vm: IndicatorViewModel?
        func shot(_ name: String) {
            let t = Process()
            t.launchPath = "/usr/sbin/screencapture"
            t.arguments = ["-x", "\(outDir)/\(name).png"]
            try? t.run(); t.waitUntilExit()
        }
        // PROBE_REAL=1: the real start path (as ShortcutManager does it: show + startRecording, the
        // mic included), frames every 150ms, then the take is DISCARDED (stopForce) — nothing is
        // transcribed or pasted.
        if ProcessInfo.processInfo.environment["PROBE_REAL"] != nil {
            var real: [(Double, () -> Void)] = [
                (0.5, { vm = manager.show(nearPoint: nil); vm?.startRecording() }),
            ]
            for i in 0..<12 { real.append((0.52 + Double(i) * 0.15, { shot(String(format: "r%02d", i)) })) }
            real.append((2.5, { manager.stopForce() }))
            real.append((3.3, { exit(0) }))
            for (at, step) in real {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { step() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(1) }
            NSApplication.shared.run()
            exit(0)
        }
        let steps: [(Double, () -> Void)] = [
            (0.5, { vm = manager.show(nearPoint: nil); vm?.state = .recording; vm?.isBlinking = true }),
            (0.6, { shot("1-entrance") }),
            (1.4, { shot("2-recording") }),
            (1.6, { vm?.state = .decoding }),
            (1.7, { shot("3-decoding-mid") }),
            (2.4, { shot("4-decoding") }),
            (2.6, { vm?.state = .info("Copied — press ⌘V to paste") }),
            (3.2, { shot("5-info") }),
            (3.4, { manager.hide() }),
            (3.5, { shot("6-hiding") }),
            (4.2, { exit(0) }),
        ]
        for (at, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { step() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(1) }
        NSApplication.shared.run()
        exit(0)
    }
}

#endif
