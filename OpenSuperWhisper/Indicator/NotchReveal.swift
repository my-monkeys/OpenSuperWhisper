import SwiftUI

/// The bubble's entrance, as a mask that starts out exactly the size of the cutout and opens to
/// the whole bubble.
///
/// Used as a mask rather than applied to the view, and that is the entire point. The three
/// entrances before this one scaled the view tree instead, which does not reveal content, it
/// squashes it: the spectrum bars went in at a third of their width and stretched back out,
/// the label started as illegible compressed glyphs, and the shape's rounded corners came in
/// oval. Masking leaves every point of the bubble at its final size and simply uncovers it.
///
/// At zero it is the notch and nothing else, so the first frame is hidden behind the hardware
/// and the bubble looks like it grew out of it. Anchored to the top edge and centred, because
/// that is where the hardware is.
struct NotchReveal: Shape {
    /// 0 = exactly the cutout, 1 = the full bubble.
    var progress: CGFloat
    var cutout: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let eased = min(max(progress, 0), 1)
        let width = cutout.width + (rect.width - cutout.width) * eased
        let height = cutout.height + (rect.height - cutout.height) * eased
        let opening = CGRect(x: rect.midX - width / 2, y: rect.minY,
                             width: width, height: max(height, 0))
        return NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: opening)
    }
}
