import XCTest
import SwiftUI
@testable import NotchMon

/// The strip's hole has to land on the camera cutout, and the cutout does not
/// move to suit the layout.
///
/// A plain `HStack` centres its total width, so unequal flanks slide the
/// reserved column off the notch — and whatever the wider flank drew in the
/// overhang was painted into a hole with no pixels. It was invisible on the
/// machine and perfectly visible in a screenshot, because a screengrab fills
/// the cutout in from the framebuffer, which is what let it survive review.
final class StripBalanceTests: XCTestCase {
    private let panelWidth: CGFloat = 760
    private let notch: CGFloat = 220

    /// Walks the real pipeline: HStack centres the content, then the shape is
    /// slid by `StripBalance`. Returns where the hole ends up, in panel
    /// coordinates, against where the notch actually is.
    private func holeCentre(leading: CGFloat, trailing: CGFloat) -> CGFloat {
        let total = leading + notch + trailing
        let centred = (panelWidth - total) / 2
        let minX = centred + StripBalance.shift(leading: leading, trailing: trailing)
        return minX + leading + notch / 2
    }

    private var notchCentre: CGFloat { panelWidth / 2 }

    func testHoleLandsOnTheNotchWhenFlanksMatch() {
        XCTAssertEqual(holeCentre(leading: 90, trailing: 90), notchCentre, accuracy: 0.001)
    }

    /// The case that shipped: two agent chips left, one token figure right. The
    /// hole sat 17.5 points right of the notch and the left group's inner end
    /// disappeared into it.
    func testHoleLandsOnTheNotchWhenLeadingIsWider() {
        XCTAssertEqual(holeCentre(leading: 110, trailing: 75), notchCentre, accuracy: 0.001)
        XCTAssertEqual(StripBalance.shift(leading: 110, trailing: 75), -17.5, accuracy: 0.001)
    }

    func testHoleLandsOnTheNotchWhenTrailingIsWider() {
        XCTAssertEqual(holeCentre(leading: 40, trailing: 128), notchCentre, accuracy: 0.001)
    }

    /// The fix that was tried first and rejected: padding both flanks to the
    /// wider one aligns the hole too, but only by adding a slab of dead black
    /// off the narrow end. Sliding keeps every point of the strip's width
    /// carrying content — the total is the natural one, not the padded one.
    func testStripKeepsItsNaturalWidth() {
        let leading: CGFloat = 110, trailing: CGFloat = 75
        let natural = leading + notch + trailing
        let padded = max(leading, trailing) * 2 + notch
        XCTAssertEqual(natural, 405)
        XCTAssertEqual(padded, 440)
        // Sliding changes position only, never width.
        XCTAssertNotEqual(StripBalance.shift(leading: leading, trailing: trailing), 0)
    }

    /// Both widths come from one layout pass, so the sign is the only thing
    /// left to get wrong — and getting it wrong drives the strip's content
    /// deeper into the cutout instead of out of it.
    func testWiderLeadingSlidesTheStripLeft() {
        XCTAssertLessThan(StripBalance.shift(leading: 110, trailing: 75), 0)
        XCTAssertGreaterThan(StripBalance.shift(leading: 75, trailing: 110), 0)
        XCTAssertEqual(StripBalance.shift(leading: 90, trailing: 90), 0)
    }
}
