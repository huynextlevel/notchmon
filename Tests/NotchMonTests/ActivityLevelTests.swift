import XCTest
@testable import NotchMon

/// The two windows, and the bug that produced them.
///
/// The first version had one window of eight seconds keyed on file writes. Two
/// things went wrong at once, and both were the same thing: measured on a live
/// session, an agent that was thinking left a **26-second** gap between writes,
/// so the mark went dark mid-task — and since each agent was lit for only eight
/// seconds after each of its own writes, two agents working together almost
/// never overlapped and read as taking turns.
@MainActor
final class ActivityLevelTests: XCTestCase {
    /// The gap that was actually measured has to stay lit. This is the test
    /// that would have caught the bug.
    func testTheMeasuredThinkingGapStaysLit() {
        XCTAssertEqual(ActivityLevel.at(quietFor: 26), .settling)
    }

    func testAFreshWriteIsLively() {
        XCTAssertEqual(ActivityLevel.at(quietFor: 0), .lively)
        XCTAssertEqual(ActivityLevel.at(quietFor: 11.9), .lively)
    }

    func testQuietBecomesSettlingRatherThanNothing() {
        XCTAssertEqual(ActivityLevel.at(quietFor: 12.1), .settling)
        XCTAssertEqual(ActivityLevel.at(quietFor: 49), .settling)
    }

    /// It has to end. A session you have finished with must stop moving while
    /// you are still looking at the strip.
    func testItEventuallyGoesOut() {
        XCTAssertNil(ActivityLevel.at(quietFor: 51))
        XCTAssertNil(ActivityLevel.at(quietFor: 600))
    }

    /// Two agents whose writes are half a minute apart are both in a task, so
    /// both must be lit at once — the alternation was the visible half of the
    /// bug.
    func testTwoAgentsThirtySecondsApartOverlap() {
        XCTAssertNotNil(ActivityLevel.at(quietFor: 30))
        XCTAssertNotNil(ActivityLevel.at(quietFor: 2))
    }

    /// Quiet reads as calmer, not as identical: the level is told apart by
    /// rhythm and brightness, not by colour, which belongs to the vendor.
    func testSettlingIsSlowerAndDimmer() {
        XCTAssertGreaterThan(ActivityLevel.settling.pace, ActivityLevel.lively.pace)
        XCTAssertLessThan(ActivityLevel.settling.opacity, ActivityLevel.lively.opacity)
    }
}
