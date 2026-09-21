import SwiftUI

// The design catalog. Open this file in Xcode, show the Canvas (⌥⌘↩), switch between the tabs at the
// top of the Canvas, and run the moving one in Live mode (▶). Every tab shows the SAME component —
// `RecordingBubble`, the app's constrained Liquid Glass bubble — so what the previews show is what
// the app renders. Glass renders for real here because this package has no native dependencies.

// MARK: - Previews

#Preview("Recording bubble") {
    if #available(macOS 26.0, *) { RecordingBubbleDemo() } else { Unsupported() }
}

#Preview("Layouts") {
    if #available(macOS 26.0, *) {
        DesktopBackdrop(size: CGSize(width: 620, height: 380)) { LayoutColumn() }
    } else { Unsupported() }
}

#Preview("Backdrops") {
    if #available(macOS 26.0, *) {
        HStack(spacing: 0) {
            ForEach(BackdropStyle.allCases, id: \.self) { style in
                DesktopBackdrop(style: style, scheme: style.preferredScheme,
                                size: CGSize(width: 320, height: 300)) {
                    RecordingBubble(showDot: true, center: [.waveform, .label], onStop: {}, onCancel: {})
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
                        RecordingBubble(showDot: true, center: [.waveform, .label],
                                        glass: kind, onStop: {}, onCancel: {})
                        PreviewLabel(kind.displayName)
                    }
                }
            }
        }
    } else { Unsupported() }
}

// MARK: - Interactive emerge demo

/// The bubble emerging: the dot necks out on the left, Stop/Cancel on the right, all from the pill.
/// Loops; "Emerge/Collapse" toggles by hand and "Swap centre" reorders the waveform and label.
@available(macOS 26.0, *)
struct RecordingBubbleDemo: View {
    @State private var expanded = true
    @State private var autoplay = true
    @State private var swap = false

    var body: some View {
        DesktopBackdrop {
            VStack(spacing: 26) {
                RecordingBubble(
                    showDot: true,
                    center: swap ? [.label, .waveform] : [.waveform, .label],
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
                    Toggle("Auto", isOn: $autoplay).toggleStyle(.switch)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.white).foregroundStyle(.white)
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

// MARK: - Layout matrix

/// The constrained layout across a few configurations: the dot is always leftmost, Stop/Cancel are
/// always rightmost, only the waveform and the label reorder, and any element can be off.
@available(macOS 26.0, *)
struct LayoutColumn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LayoutRow("Dot · waveform · label · Stop · Cancel") {
                RecordingBubble(showDot: true, center: [.waveform, .label], onStop: {}, onCancel: {})
            }
            LayoutRow("Centre swapped: label · waveform") {
                RecordingBubble(showDot: true, center: [.label, .waveform], onStop: {}, onCancel: {})
            }
            LayoutRow("No dot") {
                RecordingBubble(showDot: false, center: [.waveform, .label], onStop: {}, onCancel: {})
            }
            LayoutRow("Waveform only · Stop only") {
                RecordingBubble(showDot: true, center: [.waveform], onStop: {})
            }
            LayoutRow("Label only, no controls") {
                RecordingBubble(showDot: true, center: [.label])
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
            content.frame(width: 330, alignment: .center)
            PreviewLabel(title).frame(width: 210, alignment: .leading)
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

/// A caption beside a sample, in Tahoe's header style: title-case, a semantic text style, no all-caps
/// and no tracking. Over the vivid backdrops the secondary hierarchy is too faint, so it keeps an
/// explicit white at reduced opacity.
struct PreviewLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
    }
}

enum BackdropStyle: CaseIterable {
    case aurora, bright, busy

    var preferredScheme: ColorScheme { self == .bright ? .light : .dark }

    var gradient: LinearGradient {
        switch self {
        case .aurora:
            return LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.28),
                                           Color(red: 0.42, green: 0.16, blue: 0.52),
                                           Color(red: 0.10, green: 0.40, blue: 0.52)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .bright:
            return LinearGradient(colors: [Color(red: 0.98, green: 0.96, blue: 0.92),
                                           Color(red: 0.86, green: 0.90, blue: 0.98),
                                           Color(red: 0.95, green: 0.88, blue: 0.82)],
                                  startPoint: .top, endPoint: .bottom)
        case .busy:
            return LinearGradient(colors: [Color(red: 0.90, green: 0.35, blue: 0.25),
                                           Color(red: 0.20, green: 0.55, blue: 0.35),
                                           Color(red: 0.15, green: 0.30, blue: 0.85)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Glass samples and refracts whatever sits behind it, so a preview over a flat fill tells you
/// nothing. This puts the bubble over a vivid, slightly busy stand-in desktop so the lensing along
/// the bubble's edge is visible.
struct DesktopBackdrop<Content: View>: View {
    var style: BackdropStyle = .aurora
    var scheme: ColorScheme = .dark
    var size = CGSize(width: 560, height: 360)
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            style.gradient
            ornaments
            content
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
    }

    private var ornaments: some View {
        ZStack {
            Circle().fill(.white.opacity(0.14)).frame(width: 150).offset(x: -180, y: -90)
            Circle().fill(.black.opacity(0.16)).frame(width: 110).offset(x: 190, y: 110)
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08))
                .frame(width: 240, height: 64).offset(x: 140, y: -110)
            HStack(spacing: 26) {
                ForEach(["command", "waveform", "mic.fill", "text.cursor", "sparkles"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 30))
                }
            }
            .foregroundStyle(.white.opacity(0.16))
            .offset(y: 140)
        }
    }
}
