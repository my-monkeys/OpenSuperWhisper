import SwiftUI

// The reusable Liquid Glass primitives for the recording bubble, built on the real morphing API.
//
// The bubble emerges from a SINGLE glass piece, macOS-Spotlight style: the pill is the constant
// glass "bar", and the Stop/Cancel controls slide OUT of it as separate glass shapes. While they
// travel, the `GlassEffectContainer` blends any two shapes whose edges are within its `spacing`, so
// the material stretches into a neck and pinches off as each control clears the bar — and melts
// back into the bar on collapse.
//
// How the necking is produced (and why toggling the controls' presence alone reads as a fade):
//  - The controls are ALWAYS in the hierarchy. Collapsed, each one is `.offset` back so it sits
//    exactly inside the bar's trailing cap; overlapping shapes in a container union into one, so the
//    collapsed state renders as just the bar. Expanding animates the offset to zero, which is Apple's
//    own recipe for "how Liquid Glass effects react to each other in a container" (their sample
//    animates an `.offset` after `.glassEffect()`).
//  - At rest no gap between shapes (`controlGap` bar→Stop, `pairGap` Stop→Cancel) is smaller than
//    the container `spacing`. A container spacing larger than a layout gap makes those shapes blend
//    together *at rest*, so the expanded state is already one fused blob and nothing is ever seen
//    separating. Keeping every rest gap at/above the spacing means the shapes only merge while they
//    move — which is the neck.
//  - The bar and the controls use the same `Glass` material, so the container treats them as one
//    set of shapes to blend.
//  - `.glassEffectTransition(.materialize)` stays on every piece, but it only fires when a piece is
//    added to or removed from the hierarchy — i.e. the whole bubble's entrance/exit (`visible`), never
//    the emerge, so it cannot override the necking.
//
// This package targets macOS 26 for the glass APIs (guarded with `@available(macOS 26.0, *)` so the
// package's platform can stay at a version Xcode recognises for previews).

// MARK: - Glass material

/// The glass variants worth comparing for the bubble. `regular` is what the bubble ships with
/// today; `clear` is the more transparent one the redesign is moving toward; the tinted pair adds a
/// dark wash for legibility over bright backdrops.
public enum GlassKind: String, CaseIterable, Sendable {
    case regular
    case clear
    case clearTinted
    case regularTinted

    /// Title-case name for labels (Tahoe labels and section headers are no longer all-caps).
    public var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .clear: return "Clear"
        case .clearTinted: return "Clear, Tinted"
        case .regularTinted: return "Regular, Tinted"
        }
    }

    @available(macOS 26.0, *)
    var glass: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        case .clearTinted: return .clear.tint(.black.opacity(0.35))
        case .regularTinted: return .regular.tint(.black.opacity(0.30))
        }
    }
}

// MARK: - Bubble states

/// The states the design cares about — the visually distinct shapes the glass has to hold: a
/// compact recording pill, a growing live caption, and the short prose the message states show.
public enum BubbleState: Equatable, Sendable {
    case recording          // red dot + "Recording…"
    case caption            // red dot + streaming text
    case message(String)    // decoding / info / error prose
}

// MARK: - The bubble

/// A faithful stand-in for the recording bubble. All of it lives in one `GlassEffectContainer`: the
/// pill is the constant bar (`glassEffectID("core")`), and the Stop/Cancel controls are separate
/// glass circles that slide out of the bar's trailing cap when `expanded` flips on and slide back
/// into it when it flips off. The bubble owns that choreography — flip `expanded` (with or without
/// `withAnimation`) and it animates itself. `visible` drives the bubble's own entrance/exit.
@available(macOS 26.0, *)
public struct BubbleView: View {
    var state: BubbleState
    var glass: GlassKind
    var showButtons: Bool
    var blinking: Bool
    /// Show the live spectrum meter (the "audiform") in the recording/caption states.
    var showWaveform: Bool

    /// Real spectrum bands (0…1) from the app's analyser. When nil, the meter synthesises a signal
    /// so previews still move.
    var bands: [Float]?
    /// Real actions for the on-bubble controls. When either is set, the controls are driven by these
    /// (each shown only if its action is set) instead of the demo `showButtons` pair.
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Live caption text from the app; overrides the demo caption in the `.caption` state.
    var liveText: AttributedString?
    /// Emerge the controls out of the bar once when the bubble appears (the app's entrance). When
    /// false, `expanded` drives them directly (the demos toggle it by hand).
    var emergeOnAppear: Bool

    /// Collapsed = only the bar; expanded = the controls are out beside it. Animating this is the
    /// Spotlight-style emerge (the controls neck out of the bar).
    var expanded: Bool

    /// Whether the bubble is on screen at all. Toggling this materializes/dissolves the glass — the
    /// bubble's own entrance. Keep the `BubbleView` in the hierarchy and flip this rather than
    /// removing the view, so the container is around to run the transition.
    var visible: Bool

    /// Layout gap between the bar and the first control at rest — the room the neck has to form.
    var controlGap: CGFloat

    /// Layout gap between the two controls at rest: tighter, so they read as one pair of buttons.
    var pairGap: CGFloat

    /// How close two glass shapes must be before they start to merge. Keep it at or below the
    /// smallest rest gap (`pairGap`), so nothing is bridged at rest and the shapes only merge while
    /// they move — the neck. Equal to a gap means that pair has *just* pinched off on settle
    /// (Apple's own morph sample uses equal values); raising it toward `controlGap` lengthens the
    /// bar→control neck at the cost of a web between the two controls at rest.
    var containerSpacing: CGFloat

    /// The controls are 24pt symbols with 6pt padding: a 36pt circle, matching the bar's height so
    /// a tucked control coincides with the bar's rounded cap and disappears into it completely.
    static let controlSize: CGFloat = 36

    /// The emerge curve: a light spring so the controls overshoot a hair and settle back, which is
    /// where the neck visibly pinches. The second control follows the first by `stagger`.
    static let emerge = Animation.spring(duration: 0.6, bounce: 0.22)
    static let stagger: Double = 0.07

    @Namespace private var glassNS

    public init(state: BubbleState,
                glass: GlassKind = .clear,
                showButtons: Bool = false,
                blinking: Bool = false,
                showWaveform: Bool = false,
                bands: [Float]? = nil,
                onStop: (() -> Void)? = nil,
                onCancel: (() -> Void)? = nil,
                liveText: AttributedString? = nil,
                emergeOnAppear: Bool = false,
                expanded: Bool = true,
                visible: Bool = true,
                controlGap: CGFloat = 6,
                pairGap: CGFloat = 6,
                containerSpacing: CGFloat = 8) {
        self.state = state
        self.glass = glass
        self.showButtons = showButtons
        self.blinking = blinking
        self.showWaveform = showWaveform
        self.bands = bands
        self.onStop = onStop
        self.onCancel = onCancel
        self.liveText = liveText
        self.emergeOnAppear = emergeOnAppear
        self.expanded = expanded
        self.visible = visible
        self.controlGap = controlGap
        self.pairGap = pairGap
        self.containerSpacing = containerSpacing
    }

    @State private var appeared = false

    /// The controls, either app-driven (real actions) or the demo pair.
    private struct Control { let system, id: String; let label: LocalizedStringKey; let tint: Color; let action: () -> Void }
    private var controls: [Control] {
        if onStop != nil || onCancel != nil {
            var c: [Control] = []
            if let onStop { c.append(.init(system: "stop.fill", id: "stop", label: "Stop Recording", tint: .red, action: onStop)) }
            if let onCancel { c.append(.init(system: "trash", id: "trash", label: "Cancel Recording", tint: .primary, action: onCancel)) }
            return c
        }
        if showButtons {
            return [.init(system: "stop.fill", id: "stop", label: "Stop Recording", tint: .red, action: {}),
                    .init(system: "trash", id: "trash", label: "Cancel Recording", tint: .primary, action: {})]
        }
        return []
    }

    /// Controls tuck when collapsed and slide out when expanded. `emergeOnAppear` starts collapsed
    /// and expands once on appear (the app's entrance); otherwise `expanded` drives it (the demos).
    private var effectiveExpanded: Bool { emergeOnAppear ? appeared : expanded }

    public var body: some View {
        GlassEffectContainer(spacing: containerSpacing) {
            if visible {
                HStack(spacing: controlGap) {
                    core
                    if !controls.isEmpty {
                        HStack(spacing: pairGap) {
                            ForEach(Array(controls.enumerated()), id: \.offset) { index, control in
                                controlButton(control, index: index)
                            }
                        }
                    }
                }
            }
        }
        // The entrance emerge: the controls start tucked in the bar and neck out once on appear.
        .onAppear { if emergeOnAppear { appeared = true } }
    }

    /// The one piece the controls come out of — the constant "bar", like Spotlight's search field.
    /// Its `materialize` transition only runs when the bar itself enters/leaves (`visible`).
    private var core: some View {
        HStack(spacing: 10) {
            recordDot
            if showWaveform && isLive {
                WaveformMeter(height: 18, bands: bands)
                    // The bars are content, not glass (recipes §1: content stays out of glass), so
                    // they live inside the bar. Insert/remove them with a spring so they don't pop.
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(minHeight: Self.controlSize)
        .glassEffect(glass.glass, in: .capsule)
        .glassEffectID("core", in: glassNS)
        .glassEffectTransition(.materialize)
        .overlay { rim }
    }

    /// A control as its own glass circle in the same material as the bar. It is always present;
    /// collapsed, it is offset back by `tuck` so it lies exactly inside the bar's trailing cap
    /// (unioned away), and expanding animates the offset to zero. The offset is applied AFTER the
    /// glass modifiers so the glass shape itself travels, which is what the container blends.
    ///
    /// Iconography: a single semantic symbol font at medium weight, monochrome rendering, and an
    /// accessibility label for the icon-only button (every icon gets one).
    private func controlButton(_ control: Control, index: Int) -> some View {
        Button(action: control.action) {
            Image(systemName: control.system)
                .font(.body.weight(.medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(control.tint)
                .frame(width: 24, height: 24)
                .padding(6)
                .contentShape(Rectangle())
                // Only the symbol fades — it is inside the glass, so the shape stays whole. It
                // appears once the control has mostly cleared the bar, and drops out first on
                // collapse, so it never crosses the bar's label.
                .opacity(effectiveExpanded ? 1 : 0)
                .animation(iconAnimation(index: index), value: effectiveExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.label)
        .glassEffect(glass.glass.interactive(), in: .capsule)
        .glassEffectID(control.id, in: glassNS)
        .glassEffectTransition(.materialize)
        .offset(x: effectiveExpanded ? 0 : -tuck(index: index))
        .animation(emergeAnimation(index: index), value: effectiveExpanded)
    }

    /// Distance from a control's rest position back to the bar's trailing cap, so both controls
    /// start from the same spot inside the bar. The first control crosses its own width plus the
    /// bar gap; the second additionally crosses the first control and the (tighter) pair gap.
    private func tuck(index: Int) -> CGFloat {
        CGFloat(index + 1) * Self.controlSize + controlGap + CGFloat(index) * pairGap
    }

    /// Emerging: the nearer control leads. Collapsing: the farther one melts back first.
    private func emergeAnimation(index: Int) -> Animation {
        let order = effectiveExpanded ? index : (1 - index)
        return Self.emerge.delay(Double(order) * Self.stagger)
    }

    private func iconAnimation(index: Int) -> Animation {
        let order = effectiveExpanded ? index : (1 - index)
        let lag = Double(order) * Self.stagger
        return effectiveExpanded
            ? .easeOut(duration: 0.25).delay(0.2 + lag)
            : .easeIn(duration: 0.12).delay(lag)
    }

    /// Recording and live-caption are the states where the mic is open, so the audiform belongs.
    private var isLive: Bool {
        state == .recording || state == .caption
    }

    /// The live indicator: a filled symbol at a semantic size, breathing with the system's own
    /// `pulse` symbol effect instead of a hand-rolled opacity loop. Decorative — the label says
    /// "Recording", so it is hidden from accessibility.
    private var recordDot: some View {
        Image(systemName: "circle.fill")
            .font(.caption2)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.red)
            .symbolEffect(.pulse, options: .repeating, isActive: blinking)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    /// Semantic text styles (`.body` is the 13pt macOS control size) with a hierarchical
    /// foreground: the state label and the confirmed caption are primary, status prose and the
    /// still-streaming caption tail step down to secondary.
    @ViewBuilder private var content: some View {
        switch state {
        case .recording:
            Text("Recording…")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        case .caption:
            Text(liveText ?? captionText)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
        case .message(let text):
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// The faint specular hairline along the top of the glass, fading out toward the bottom — the
    /// crisper top highlight the system's own glass capsules show.
    private var rim: some View {
        Capsule().stroke(
            LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 1)
    }

    /// The confirmed part reads normal, the still-streaming tail dims — the live-caption look.
    private var captionText: AttributedString {
        let confirmed = AttributedString("hello world this is a ")
        var volatile = AttributedString("dictation")
        volatile.foregroundColor = .secondary
        return confirmed + volatile
    }
}

// MARK: - Audiform

/// The live mic spectrum — the "audiform" — faithful to the app's `InputLevelMeter`: seven capsule
/// bars, `Color.secondary` brightening with each band's level. There is no mic in a preview, so the
/// levels are synthesised (layered sines, phase-shifted per band, weighted toward the middle bands
/// the way a voice is) and driven by a `TimelineView(.animation)` so the bars flow continuously.
///
/// The motion is the liquid part: the levels are smooth continuous functions of time, so each
/// frame's heights differ only slightly and the bars swell and settle like fluid rather than
/// snapping — and the whole meter breathes with a slow amplitude envelope so it never reads as a
/// fixed loop. The bars are content, so they carry no glass of their own; they sit inside the bar.
public struct WaveformMeter: View {
    var height: CGFloat
    /// Real spectrum levels (0…1) from the app. When nil, the levels are synthesised so previews
    /// still move; when set, the bars follow the mic and one bar is drawn per band.
    var bands: [Float]?

    public init(height: CGFloat = 18, bands: [Float]? = nil) {
        self.height = height
        self.bands = bands
    }

    private var bandCount: Int { bands?.count ?? 7 }

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2.5
    private static let restHeight: CGFloat = 2.5

    /// The meter's footprint for `bands` bars, so a stand-in (the transcribing spinner) can take
    /// exactly its place.
    public static func width(bands: Int) -> CGFloat {
        CGFloat(bands) * barWidth + CGFloat(max(bands - 1, 0)) * barSpacing
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<bandCount, id: \.self) { band in
                    let level = level(band: band, t: t)
                    Capsule()
                        .fill(Color.primary.opacity(0.55 + 0.45 * level))
                        .frame(width: Self.barWidth,
                               height: Self.restHeight + (height - Self.restHeight) * level)
                }
            }
            .frame(height: height)
            // Ease real-band changes like the app's own meter; the synth path is already continuous.
            .animation(.linear(duration: 0.08), value: bands)
        }
        .accessibilityHidden(true)
    }

    /// Real band level when driven by the mic, otherwise a synthesised one: two sines at different
    /// rates keep it lively, a triangular weight makes the middle bands taller (voice energy), and a
    /// slow envelope makes the whole meter rise and fall so it never looks like a fixed pattern.
    private func level(band: Int, t: Double) -> Double {
        if let bands, band < bands.count {
            return min(1, max(0, Double(bands[band])))
        }
        let phase = Double(band) * 0.9
        let slow = sin(t * 6.0 + phase) * 0.5 + 0.5
        let fast = sin(t * 12.7 + phase * 1.7) * 0.5 + 0.5
        let midWeight = 1 - abs(Double(band) - Double(bandCount - 1) / 2) / Double(bandCount)
        let envelope = 0.55 + 0.45 * (sin(t * 1.7) * 0.5 + 0.5)
        let v = (0.55 * slow + 0.45 * fast) * (0.35 + 0.65 * midWeight) * envelope
        return min(1, max(0.06, v))
    }
}

// MARK: - Reusable surface (the app's seam target)

public extension View {
    /// Apply the recording bubble's Liquid Glass surface to any content: clear glass in `shape`, the
    /// `.materialize` entrance, and the faint specular rim. On macOS < 26 (where glass does not
    /// exist) it is a passthrough — the app's theme resolves to `.legacy` there, so this is never the
    /// visible surface on older systems. This is what the app applies to its own bubble in the
    /// Liquid Glass theme, so the app and this package's previews share one glass surface.
    func liquidGlassSurface(in shape: some Shape, glass: GlassKind = .clear,
                            rim: Bool = true) -> some View {
        modifier(LiquidGlassSurfaceModifier(shape: AnyShape(shape), kind: glass, rim: rim))
    }
}

struct LiquidGlassSurfaceModifier: ViewModifier {
    let shape: AnyShape
    let kind: GlassKind
    let rim: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(kind.glass, in: shape)
                .glassEffectTransition(.materialize)
                .overlay { if rim { rimStroke } }
        } else {
            content
        }
    }

    /// The faint specular hairline along the top of the glass — the crisper top highlight the
    /// system's own glass capsules show.
    private var rimStroke: some View {
        shape.stroke(
            LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 1)
    }
}
