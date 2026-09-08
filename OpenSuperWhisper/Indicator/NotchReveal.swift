import SwiftUI

/// The opening through which the bubble is seen: a notch silhouette, centred on the hardware and
/// pinned to the top of the screen, whose width and height are animated.
///
/// A mask rather than a transform, and that is the whole point. The three entrances before this
/// one scaled the view tree instead, which does not reveal content, it squashes it: the spectrum
/// bars went in at a third of their width and stretched back out, the label started as illegible
/// compressed glyphs, and the rounded corners came in oval. A mask leaves every point of the
/// bubble at its final size and simply uncovers it.
///
/// Both dimensions are **points**, not a fraction of the bubble. A fraction was enough for the
/// entrance and useless for everything after it: `path(in:)` is handed a new rect the instant the
/// content grows, and a fraction of a rect that changed under it has nothing left to interpolate.
/// So the pill snapped to its new height with no animation at all — most visibly when a clip came
/// back with nothing in it and the bubble had to drop down to say so. Points are a value SwiftUI
/// can animate between, whatever the rect does.
struct NotchReveal: Shape {
    /// Closed, this is the cutout: the first frame is indistinguishable from the hardware, so the
    /// bubble looks like it grew out of it.
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set { width = newValue.first; height = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // Clamped because a spring overshoots at both ends, and an opening wider than the bubble
        // would show a bare rectangle of black for a frame or two.
        let openWidth = min(max(width, 0), rect.width)
        let openHeight = min(max(height, 0), rect.height)

        // `NotchShape` carves its corners out of the rect it is handed, so below the size those
        // corners need, the path crosses itself and encloses more than the opening asked for.
        // An opening that small has nothing worth showing, so it shows nothing.
        guard openWidth >= 2 * (topRadius + bottomRadius),
              openHeight >= topRadius + bottomRadius
        else { return Path() }

        let opening = CGRect(x: rect.midX - openWidth / 2, y: rect.minY,
                             width: openWidth, height: openHeight)
        return NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: opening)
    }
}
