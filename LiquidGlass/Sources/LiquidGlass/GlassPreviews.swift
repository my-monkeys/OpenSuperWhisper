import SwiftUI

// The design catalog. Open this file in Xcode, show the Canvas (⌥⌘↩), switch between the tabs at the
// top of the Canvas, and run the moving one in Live mode (▶). Every tab shows the SAME component —
// `RecordingBubble`, the app's constrained Liquid Glass bubble — so what the previews show is what
// the app renders. Glass renders for real here because this package has no native dependencies.

// MARK: - Previews

#Preview("Recording bubble") {
    if #available(macOS 26.0, *) { RecordingBubbleDemo() } else { Unsupported() }
}

#Preview("States") {
    if #available(macOS 26.0, *) {
        DesktopBackdrop(size: CGSize(width: 640, height: 420)) { StatesColumn() }
    } else { Unsupported() }
}

#Preview("Layouts") {
    if #available(macOS 26.0, *) {
        DesktopBackdrop(size: CGSize(width: 640, height: 380)) { LayoutColumn() }
    } else { Unsupported() }
}

#Preview("Wallpapers") {
    if #available(macOS 26.0, *) {
        HStack(spacing: 0) {
            ForEach(WallpaperStyle.allCases, id: \.self) { style in
                DesktopBackdrop(style: style, size: CGSize(width: 360, height: 300)) {
                    RecordingBubble(showDot: true, center: [.label, .waveform], onStop: {}, onCancel: {})
                }
            }
        }
    } else { Unsupported() }
}

#Preview("Glass materials") {
    if #available(macOS 26.0, *) {
        DesktopBackdrop {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(GlassKind.allCases, id: \.rawValue) { kind in
                    HStack(spacing: 16) {
                        RecordingBubble(showDot: true, center: [.label, .waveform],
                                        glass: kind, onStop: {}, onCancel: {})
                        PreviewLabel(kind.displayName)
                    }
                }
            }
        }
    } else { Unsupported() }
}

// MARK: - Interactive emerge demo

/// The controls necking out of the pill and melting back. Loops; "Emerge/Collapse" toggles by hand
/// and "Swap centre" reorders the waveform and label.
@available(macOS 26.0, *)
struct RecordingBubbleDemo: View {
    @State private var expanded = true
    @State private var autoplay = true
    @State private var swap = false
    @State private var style: WallpaperStyle = .night

    var body: some View {
        DesktopBackdrop(style: style) {
            VStack(spacing: 26) {
                RecordingBubble(
                    showDot: true,
                    center: swap ? [.waveform, .label] : [.label, .waveform],
                    labelText: "Recording…",
                    blinking: true,
                    onStop: {},
                    onCancel: {},
                    expanded: expanded
                )
                .frame(height: 84)
                HStack(spacing: 12) {
                    Button(expanded ? "Collapse" : "Emerge") { autoplay = false; expanded.toggle() }
                    Button("Swap centre") { swap.toggle() }
                    Picker("", selection: $style) {
                        ForEach(WallpaperStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle("Auto", isOn: $autoplay).toggleStyle(.switch)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }
        }
        .task(id: autoplay) {
            guard autoplay else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !autoplay { break }
                expanded.toggle()
            }
        }
    }
}

// MARK: - States

/// Every phase the bubble goes through in one column: listening, a live caption, transcribing
/// (Stop melted back in, Cancel became ✕), and the messages that can follow.
@available(macOS 26.0, *)
struct StatesColumn: View {
    private static var caption: AttributedString {
        var confirmed = AttributedString("Liquid Glass bends whatever")
        var volatile = AttributedString(" sits behind it")
        volatile.foregroundColor = .secondary
        confirmed.append(volatile)
        return confirmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LayoutRow("Recording") {
                RecordingBubble(center: [.label, .waveform], onStop: {}, onCancel: {})
            }
            LayoutRow("Live caption") {
                RecordingBubble(center: [.label], caption: Self.caption, onStop: {}, onCancel: {})
            }
            LayoutRow("Transcribing") {
                RecordingBubble(phase: .processing, center: [.label, .waveform],
                                labelText: "Transcribing…", onStop: {}, onCancel: {})
            }
            LayoutRow("Done") {
                RecordingBubble(phase: .message(symbol: "doc.on.clipboard",
                                                text: "Copied — press ⌘V to paste", tint: .primary),
                                onStop: {}, onCancel: {})
            }
            LayoutRow("Error") {
                RecordingBubble(phase: .message(symbol: "exclamationmark.triangle.fill",
                                                text: "No microphone available", tint: .red),
                                onStop: {}, onCancel: {})
            }
        }
    }
}

// MARK: - Layout matrix

/// The layout across a few configurations: the dot, waveform and label reorder freely inside the
/// pill, Stop/Cancel always sit at the trailing edge, and any element can be off.
@available(macOS 26.0, *)
struct LayoutColumn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LayoutRow("Dot · label · waveform · Stop · Cancel") {
                RecordingBubble(center: [.dot, .label, .waveform], onStop: {}, onCancel: {})
            }
            LayoutRow("Reordered: waveform · label · dot") {
                RecordingBubble(center: [.waveform, .label, .dot], onStop: {}, onCancel: {})
            }
            LayoutRow("No dot") {
                RecordingBubble(showDot: false, center: [.label, .waveform], onStop: {}, onCancel: {})
            }
            LayoutRow("Waveform only · Stop only") {
                RecordingBubble(center: [.dot, .waveform], onStop: {})
            }
            LayoutRow("Label only, no controls") {
                RecordingBubble(center: [.dot, .label])
            }
        }
    }
}

@available(macOS 26.0, *)
struct LayoutRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 16) {
            content.frame(width: 400, alignment: .leading)
            PreviewLabel(title).frame(width: 180, alignment: .leading)
        }
    }
}

// MARK: - Shared preview chrome

struct Unsupported: View {
    var body: some View {
        Text("Liquid Glass previews need macOS 26 (Tahoe) or later")
            .font(.body).foregroundStyle(.secondary).padding(40)
    }
}

/// A caption beside a sample, in Tahoe's header style: title-case, a semantic text style, no
/// all-caps and no tracking. Follows the backdrop's colour scheme.
struct PreviewLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary.opacity(0.75))
    }
}

/// Glass samples and refracts whatever sits behind it, so a preview over a flat fill tells you
/// nothing. This puts the bubble on a stand-in macOS desktop (`DesktopWallpaper`, the same one the
/// app's GIF probe uses) in the colour scheme that desktop implies.
@available(macOS 15.0, *)
struct DesktopBackdrop<Content: View>: View {
    var style: WallpaperStyle = .night
    var size = CGSize(width: 560, height: 360)
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            DesktopWallpaper(style)
            content
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(style.scheme)
        .colorScheme(style.scheme)
    }
}
