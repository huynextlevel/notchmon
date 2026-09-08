import XCTest
import SwiftUI
@testable import NotchMon

/// Which square of the year the pointer is on.
///
/// The grid is 364 squares about six points wide, so the mapping has to be
/// exact at the edges: one column out and the card names the wrong week, which
/// is worse than no card at all — a wrong date reads as data, not as a miss.
final class ActivityHitTests: XCTestCase {
    /// The real grid: the panel's 660 points less its two 34-point insets, and
    /// the height that width implies — the squares are square.
    private let width: CGFloat = 592
    private var pitch: CGFloat {
        let gaps = CGFloat(Metrics.activityWeeks - 1) * Metrics.activityGap
        return (width - gaps) / CGFloat(Metrics.activityWeeks) + Metrics.activityGap
    }
    private var bounds: CGRect {
        CGRect(x: 0, y: 0, width: width,
               height: pitch * CGFloat(ActivityGrid.rows) - Metrics.activityGap)
    }

    func testFirstSquare() {
        let hit = ActivityHit.at(CGPoint(x: 1, y: 1), in: bounds)
        XCTAssertEqual(hit?.column, 0)
        XCTAssertEqual(hit?.row, 0)
    }

    func testLastSquareOfTheYear() {
        let hit = ActivityHit.at(CGPoint(x: bounds.width - 1, y: bounds.height - 1), in: bounds)
        XCTAssertEqual(hit?.column, Metrics.activityWeeks - 1)
        XCTAssertEqual(hit?.row, ActivityGrid.rows - 1)
    }

    /// Every column has to be reachable by its own centre. An off-by-one in the
    /// pitch shows up here as a column that reports its neighbour.
    func testEveryColumnAndRowIsReachableAtItsCentre() {
        for column in 0..<Metrics.activityWeeks {
            for row in 0..<ActivityGrid.rows {
                let point = CGPoint(x: (CGFloat(column) + 0.5) * pitch - Metrics.activityGap / 2,
                                    y: (CGFloat(row) + 0.5) * pitch - Metrics.activityGap / 2)
                let hit = ActivityHit.at(point, in: bounds)
                XCTAssertEqual(hit?.column, column, "column \(column) row \(row)")
                XCTAssertEqual(hit?.row, row, "column \(column) row \(row)")
            }
        }
    }

    /// The gap between squares belongs to neither of them.
    func testGapsAreNotHits() {
        let side = pitch - Metrics.activityGap
        XCTAssertNil(ActivityHit.at(CGPoint(x: side + 1, y: 2), in: bounds))
        XCTAssertNil(ActivityHit.at(CGPoint(x: 2, y: side + 1), in: bounds))
    }

    func testOutsideTheGridIsNotAHit() {
        XCTAssertNil(ActivityHit.at(CGPoint(x: -1, y: 4), in: bounds))
        XCTAssertNil(ActivityHit.at(CGPoint(x: 4, y: -1), in: bounds))
        XCTAssertNil(ActivityHit.at(CGPoint(x: bounds.width + 1, y: 4), in: bounds))
        XCTAssertNil(ActivityHit.at(CGPoint(x: 4, y: bounds.height * 2), in: bounds))
    }

    /// The point arrives in the panel's coordinates, not the grid's, so the
    /// grid's own origin has to come off first.
    func testOriginOfTheGridIsSubtracted() {
        let offset = bounds.offsetBy(dx: 34, dy: 200)
        let hit = ActivityHit.at(CGPoint(x: 35, y: 201), in: offset)
        XCTAssertEqual(hit?.column, 0)
        XCTAssertEqual(hit?.row, 0)
    }

    /// The rect it hands back is what the card is positioned against, so it has
    /// to be the square's real box in the grid's own space.
    func testRectIsTheSquareItReports() {
        guard let hit = ActivityHit.at(CGPoint(x: 3 * pitch + 1, y: 2 * pitch + 1), in: bounds) else {
            return XCTFail("expected a hit")
        }
        XCTAssertEqual(hit.rect.minX, 3 * pitch, accuracy: 0.001)
        XCTAssertEqual(hit.rect.minY, 2 * pitch, accuracy: 0.001)
        XCTAssertEqual(hit.rect.width, pitch - Metrics.activityGap, accuracy: 0.001)
    }

    func testZeroWidthGridIsNotAHit() {
        XCTAssertNil(ActivityHit.at(.zero, in: CGRect(x: 0, y: 0, width: 0, height: 0)))
    }
}
