import XCTest
import SwiftUI
@testable import NotchMon

/// Where the panel is solid has to be where the panel is black.
///
/// The two used to be allowed to differ: the window claimed the shape's
/// bounding box, and the shape's top corners flare outward — full width at the
/// very top edge, inset by the flare a few points below it. The difference is
/// two transparent wedges, and they lie across the menu bar, so anything under
/// them stopped responding whenever the panel was open.
final class NotchShapeHitTests: XCTestCase {
    /// The expanded panel as it is actually laid out: 660 wide in a 760 panel.
    private let rect = CGRect(x: 50, y: 0, width: 660, height: 348)

    private var path: CGPath {
        NotchShape(topRadius: Metrics.expandedTopRadius,
                   bottomRadius: Metrics.expandedBottomRadius)
            .path(in: rect).cgPath
    }

    /// Leftmost point of the shape on a given scanline, to a tenth of a point.
    private func leftEdge(at y: CGFloat) -> CGFloat {
        let path = self.path
        var x = rect.minX
        while x < rect.maxX {
            if path.contains(CGPoint(x: x, y: y)) { return x }
            x += 0.1
        }
        return rect.maxX
    }

    /// The flare: the shape is at its widest against the top edge and has come
    /// in to the body's own width by `topRadius` below it. This is the whole
    /// reason the bounding box is the wrong hit region.
    func testShapeNarrowsAcrossTheFlare() {
        let atTop = leftEdge(at: 0.5)
        let belowFlare = leftEdge(at: Metrics.expandedTopRadius + 1)
        XCTAssertLessThan(atTop, belowFlare)
        XCTAssertEqual(belowFlare, rect.minX + Metrics.expandedTopRadius, accuracy: 0.6)
    }

    /// Below the flare the drawn edge has come in by `topRadius`, and the strip
    /// between that edge and the box is transparent.
    func testFlareWedgesAreNotPartOfTheShape() {
        let belowFlare = Metrics.expandedTopRadius + 1
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 2, y: belowFlare)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 2, y: belowFlare)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - Metrics.expandedTopRadius - 2,
                                            y: belowFlare)))
    }

    /// The regression that prompted this: at menu-bar height the wedge covers
    /// the first points of the neighbouring status item, which is a real icon
    /// on a real menu bar and has to stay clickable.
    func testMenuBarHeightIsClearOutsideTheDrawnEdge() {
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 5, y: 19)))
    }

    func testControlsInTheHeaderAreStillSolid() {
        // The gear, 26 + 25 points in from the trailing content edge.
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 38, y: 19)))
        // The tabs, just past the leading inset.
        XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 40, y: 19)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.height / 2)))
    }

    func testBelowTheShapeIsNotSolid() {
        XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: rect.maxY + 1)))
    }
}
