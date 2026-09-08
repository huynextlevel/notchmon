import SwiftUI

/// The silhouette that welds an overlay onto the hardware notch.
///
/// Two different corner treatments, and the top pair is the one that does the
/// work. A plain rounded rectangle hanging from the top edge reads as a card
/// someone stuck on the screen. Curving the top corners the *other* way — so
/// the shape flares outward as it meets the bezel — is how the real notch's
/// own moulding behaves, and it is what makes a grown panel look like the notch
/// widening rather than a second object appearing beneath it.
///
/// Drawn in SwiftUI's coordinates: y grows downward, `rect.minY` is the screen's
/// top edge.
struct NotchShape: Shape {
    /// The outward flare where the shape meets the top edge.
    var topRadius: CGFloat
    /// The ordinary rounding on the two bottom corners.
    var bottomRadius: CGFloat

    /// Both radii animate, so a shape growing from notch-sized to panel-sized
    /// can relax its corners on the way instead of holding a tight fillet at
    /// full size.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // The flares are cut out of the shape's own width, so `rect` stays the
        // shape's true extent and callers can size it without compensating.
        let top = max(0, min(topRadius, rect.width / 2))
        let body = rect.insetBy(dx: top, dy: 0)
        let bottom = max(0, min(bottomRadius, min(body.width / 2, rect.height - top)))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left flare: out of the bezel and down into the body.
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: rect.minY + top),
            control: CGPoint(x: body.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + bottom, y: rect.maxY),
            control: CGPoint(x: body.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: body.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: rect.minY + top))
        // Right flare, back out to the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: body.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
