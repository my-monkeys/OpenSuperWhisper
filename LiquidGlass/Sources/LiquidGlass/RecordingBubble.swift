import SwiftUI

// The app-shaped recording bubble, with the Liquid Glass layout constraints baked in:
//
//   ( dot · waveform / label — reorderable )   [ stop ] [ cancel ]
//     ↑ the central pill, dot always first        ↑ rightmost, fixed
//
// The two controls are SEPARATE glass shapes that neck out of the pill's trailing cap. Everything
// is in one `GlassEffectContainer`, so a control merges into the pill when tucked and pinches off
// as it slides out — the Spotlight emerge.
//
// The bubble stays the same view for its whole life (recording → transcribing → a message), so a
// phase change is a morph, never a swap: on stop, the Stop control melts back into the pill while
// Cancel slides over into its place; on a message both melt away and the pill reshapes around it.

/// A reorderable element of the pill.
public enum BubbleCenterElement: String, Sendable, CaseIterable {
    case dot
    case waveform
    case label
}

/// What the bubble is doing.
public enum BubblePhase: Equatable, Sendable {
    /// Listening: blinking dot, live waveform, both controls out.
    case recording
    /// The clip is being transcribed: the waveform becomes a spinner in its own footprint, the
    /// label says so, Stop melts back in (nothing left to stop), Cancel stays (throw it away).
    case processing
    /// A one-line message in place of the elements (connecting, error, info…). Controls tucked.
    case message(symbol: String?, text: String, tint: MessageTint)
}

/// A message's colour, kept as a small closed set so the phase stays `Equatable`/`Sendable`.
public enum MessageTint: Sendable {
    case primary, orange, red, accent
    var color: Color {
        switch self {
        case .primary: return .primary
        case .orange: return .orange
        case .red: return .red
        case .accent: return .accentColor
        }
    }
}

@available(macOS 26.0, *)
public struct RecordingBubble: View {
    var phase: BubblePhase
    var showDot: Bool
    var center: [BubbleCenterElement]
    var labelText: String
    var caption: AttributedString?
    var bands: [Float]?
    var blinking: Bool
    var waveformHeight: CGFloat
    /// Overall size factor for the whole family (pill, controls, glyphs, text, waveform). 1 is
    /// the full Spotlight-sized bar; the app lets the user pick it.
    var size: CGFloat
    var glass: GlassKind
    /// Whether the bubble is on screen. Showing and hiding go through the glass's own
    /// `.materialize` transition — NOT scale/blur/opacity from outside: glass is composited by the
    /// system on its own layer and ignores those, so an outside entrance animates the content
    /// while the glass pops, which reads as two bubbles on top of each other.
    var visible: Bool
    /// Strength of the edge highlight (0 = none). Glass takes its edge from what is behind it, so
    /// over a dark, flat window the edge all but disappears; this hairline keeps it readable.
    /// It is drawn as the glass view's own CONTENT (before `.glassEffect`), so it materialises,
    /// moves and morphs with the glass — an overlay after it lives on another layer and ghosts.
    var rim: Double
    /// A dimming layer inside the glass (black at this opacity). Glass takes its brightness from
    /// what is behind it, so over a bright window it turns light grey and white text on it drops
    /// under legible contrast; the dim keeps the pill dark enough for its text, as Apple's guidance
    /// for text on glass recommends.
    var dim: Double
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Emerge the controls out of the pill once when the bubble appears (the app's entrance).
    var emergeOnAppear: Bool
    /// When `emergeOnAppear` is false, this drives the emerge directly (the previews toggle it).
    var expanded: Bool

    public init(phase: BubblePhase = .recording,
                showDot: Bool = true,
                center: [BubbleCenterElement] = [.waveform, .label],
                labelText: String = "Recording…",
                caption: AttributedString? = nil,
                bands: [Float]? = nil,
                blinking: Bool = true,
                waveformHeight: CGFloat = 18,
                size: CGFloat = 1,
                glass: GlassKind = .regular,
                visible: Bool = true,
                rim: Double = 0.45,
                dim: Double = 0.35,
                onStop: (() -> Void)? = nil,
                onCancel: (() -> Void)? = nil,
                emergeOnAppear: Bool = false,
                expanded: Bool = true) {
        self.phase = phase
        self.showDot = showDot
        self.center = center
        self.labelText = labelText
        self.caption = caption
        self.bands = bands
        self.blinking = blinking
        self.waveformHeight = waveformHeight
        self.size = size
        self.glass = glass
        self.visible = visible
        self.rim = rim
        self.dim = dim
        self.onStop = onStop
        self.onCancel = onCancel
        self.emergeOnAppear = emergeOnAppear
        self.expanded = expanded
    }

    // Spotlight's proportions, measured off macOS 26's own search bar: the controls are circles
    // exactly as tall as the pill (so a tucked control is the pill's rounded cap), the gap is a
    // fifth of that height, glyphs are ~45% of it and the text ~40%. Glyphs are Spotlight's light
    // grey outlines; the red dot is the one colour, and it says "recording" on its own. Everything derives from the
    // one bar height, so the family stays in proportion at any waveform size.
    /// The pill's (and each control's) height: the waveform plus Spotlight-like breathing room.
    private var bar: CGFloat { max(26, ((waveformHeight + 16) * size).rounded()) }
    /// The waveform at the chosen size.
    private var meterHeight: CGFloat { (waveformHeight * size).rounded() }
    private var gap: CGFloat { (bar * 0.2).rounded() }
    // The container spacing must be BELOW the rest gap, or the glass shapes blend into one blob at
    // rest (recipes §3.2): separate at rest, necking only while a control moves.
    private var containerSpacing: CGFloat { gap - 2 }
    private var slot: CGFloat { bar + gap }
    private var textSize: CGFloat { (bar * 0.4).rounded() }
    private var glyphSize: CGFloat { (bar * 0.45).rounded() }
    // Quick and a little springy: the bubble is a transient HUD, it should snap into place.
    static let emerge = Animation.spring(duration: 0.34, bounce: 0.2)
    private static let stagger: Double = 0.04
    static let morph = Animation.spring(duration: 0.3, bounce: 0.12)

    @Namespace private var ns
    /// The pill has materialised (first step of the entrance).
    @State private var coreIn = false
    /// The controls have necked out of it (second step, a beat later).
    @State private var controlsOut = false

    /// The glass is on screen at all.
    private var shown: Bool { visible && (emergeOnAppear ? coreIn : true) }
    /// The controls are out (the emerge has run, or the preview says so).
    private var emerged: Bool { shown && (emergeOnAppear ? controlsOut : expanded) }
    private var stopOut: Bool { emerged && phase == .recording }
    private var cancelOut: Bool { emerged && (phase == .recording || phase == .processing) }

    public var body: some View {
        GlassEffectContainer(spacing: containerSpacing) {
            HStack(spacing: gap) {
                // The layout never changes with visibility (a hidden stand-in holds the pill's
                // size), so the window is sized before the glass materialises into it.
                ZStack {
                    coreContent.hidden()
                    if shown { core.transition(.opacity) }
                }
                // Both controls keep their slots in every phase: a tucked control is moved (a
                // render-only offset), never removed, so the window never reflows under the pill.
                if let onStop {
                    control(system: "stop", id: "stop", tint: Color.primary.opacity(0.85), out: stopOut, order: 0,
                            tuck: 1, action: onStop)
                }
                if let onCancel {
                    // With Stop tucked, Cancel slides over into Stop's slot rather than hanging
                    // one slot out from a gap.
                    let homeShift: CGFloat = (onStop != nil && !stopOut && cancelOut) ? -slot : 0
                    control(system: phase == .processing ? "xmark" : "trash", id: "cancel",
                            tint: Color.primary.opacity(0.85), out: cancelOut, order: 1,
                            tuck: onStop != nil ? 2 : 1, home: homeShift, action: onCancel)
                }
            }
        }
        .animation(Self.morph, value: phase)
        .onAppear {
            guard emergeOnAppear else { return }
            withAnimation(Self.appear) { coreIn = true }
            // A beat after the pill forms, the controls neck out of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { controlsOut = true }
        }
    }

    public static let appear = Animation.smooth(duration: 0.28)

    // MARK: - Pieces

    /// The central pill: the dot (always first), then the waveform and the label in the chosen
    /// order — or, for a message, the message.
    private var core: some View {
        coreContent
            .background { rimStroke(rim) }
            .background { Capsule().fill(.black.opacity(dim)) }
            .glassEffect(glass.glass, in: .capsule)
            .glassEffectID("core", in: ns)
            .glassEffectTransition(.materialize)
    }

    private var coreContent: some View {
        HStack(spacing: 10) {
            switch phase {
            case .message(let symbol, let text, let tint):
                if let symbol {
                    Image(systemName: symbol).font(.system(size: glyphSize * 0.85))
                        .foregroundStyle(tint.color).frame(width: glyphSize)
                }
                Text(text)
                    .font(.system(size: textSize))
                    .foregroundStyle(tint.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            case .recording, .processing:
                // `showDot` puts the dot first when the order does not place it itself.
                if showDot && !center.contains(.dot) { recordDot }
                ForEach(Array(center.enumerated()), id: \.offset) { _, element in
                    switch element {
                    case .dot:
                        recordDot
                    case .waveform:
                        if phase == .processing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: WaveformMeter.width(bands: bands?.count ?? 7), height: meterHeight)
                                .transition(.opacity)
                        } else {
                            WaveformMeter(height: meterHeight, bands: bands)
                                .transition(.opacity)
                        }
                    case .label:
                        Text(caption ?? AttributedString(labelText))
                            // Spotlight's placeholder: regular weight, secondary grey.
                            .font(.system(size: caption == nil ? textSize : textSize * 0.85))
                            .foregroundStyle(.primary)
                            .contentTransition(.opacity)
                            .fixedSize(horizontal: caption == nil, vertical: true)
                            .frame(maxWidth: caption == nil ? nil : 300, alignment: .leading)
                    }
                }
            }
        }
        .padding(.leading, (bar * 0.36).rounded())
        .padding(.trailing, (bar * 0.42).rounded())
        .padding(.vertical, (6 * size).rounded())
        .frame(minHeight: bar)
    }

    /// The record dot, inside the pill. Pulses while listening, steady while transcribing.
    private var recordDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: (bar * 0.22).rounded()))
            .foregroundStyle(.red)
            .opacity(phase == .recording ? 1 : 0.55)
            .symbolEffect(.pulse, options: .repeating, isActive: blinking && phase == .recording)
            .frame(width: glyphSize)
    }

    /// A control glass circle on the right. `tuck` is how many slots it travels left to hide in
    /// the pill's trailing cap; `home` shifts its resting place (Cancel taking Stop's slot).
    private func control(system: String, id: String, tint: Color, out: Bool, order: Int,
                         tuck: Int, home: CGFloat = 0, action: @escaping () -> Void) -> some View {
        // A fixed slot, whether or not the glass is on screen, so visibility never moves layout.
        ZStack {
            Color.clear.frame(width: bar, height: bar)
            if shown {
                controlGlass(system: system, id: id, tint: tint, out: out, order: order, tuck: tuck,
                             home: home, action: action)
                    .transition(.opacity)
            }
        }
    }

    private func controlGlass(system: String, id: String, tint: Color, out: Bool, order: Int,
                              tuck: Int, home: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: glyphSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: bar, height: bar)
                .contentShape(Rectangle())
                .background { rimStroke(rim) }
                .background { Capsule().fill(.black.opacity(dim)) }
                // The icon and its rim fade together, so a control still inside the pill draws no
                // ring over it.
                .opacity(out ? 1 : 0)
                .animation(iconAnimation(out: out, order: order), value: out)
        }
        .buttonStyle(PressFeedbackStyle())
        .accessibilityLabel(id == "stop" ? "Stop Recording" : "Cancel")
        .glassEffect(glass.glass.interactive(), in: .capsule)
        .glassEffectID(id, in: ns)
        .glassEffectTransition(.materialize)
        .offset(x: out ? home : -CGFloat(tuck) * slot)
        .animation(emergeAnimation(out: out, order: order), value: out)
        .animation(Self.morph, value: home)
        .allowsHitTesting(out)
    }

    /// A hairline brighter at the top (where light hits) and faint at the bottom.
    @ViewBuilder private func rimStroke(_ strength: Double) -> some View {
        if strength > 0 {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(strength), .white.opacity(strength * 0.25),
                                        .white.opacity(strength * 0.5)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
    }

    // MARK: - Timing

    /// The controls emerge Stop-then-Cancel and melt back in reverse.
    private func emergeAnimation(out: Bool, order: Int) -> Animation {
        let steps = out ? order : (1 - order)
        return Self.emerge.delay(Double(steps) * Self.stagger)
    }

    private func iconAnimation(out: Bool, order: Int) -> Animation {
        let steps = out ? order : (1 - order)
        let lag = Double(steps) * Self.stagger
        return out ? .easeOut(duration: 0.16).delay(0.1 + lag)
                   : .easeIn(duration: 0.08).delay(lag)
    }
}

/// Press feedback for the glass controls: the glyph dips and dims while held and springs back on
/// release. It lives on the label (inside the glass), so it moves with the glass rather than
/// beside it; the glass's own `.interactive()` response plays alongside.
struct PressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(duration: 0.18, bounce: 0.4), value: configuration.isPressed)
    }
}
