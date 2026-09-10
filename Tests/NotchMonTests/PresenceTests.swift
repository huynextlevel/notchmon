import XCTest
@testable import NotchMon

final class PresenceTests: XCTestCase {

    private func sample(idle: TimeInterval = 0, locked: Bool = false, onConsole: Bool = true,
                        displayOn: Bool = true, agentWorking: Bool = false,
                        ) -> Presence.Sample {
        .init(idle: idle, locked: locked, onConsole: onConsole,
              displayOn: displayOn, agentWorking: agentWorking)
    }

    // MARK: The hard negatives

    /// A closed lid, a locked screen and somebody else's login are facts, not
    /// evidence — they outrank a keyboard that was touched a second ago.
    func testCertaintiesOutrankRecentInput() {
        XCTAssertFalse(sample(idle: 1, locked: true).isPresent)
        XCTAssertFalse(sample(idle: 1, onConsole: false).isPresent)
        XCTAssertFalse(sample(idle: 1, displayOn: false).isPresent)
        XCTAssertTrue(sample(idle: 1).isPresent)
    }

    func testIdleBeyondToleranceIsAway() {
        XCTAssertTrue(sample(idle: 299).isPresent)
        XCTAssertFalse(sample(idle: 301).isPresent)
    }

    /// Watching a ten-minute build produces no keystrokes and no hook events.
    func testAWorkingAgentStretchesToleranceButDoesNotSuspendIt() {
        XCTAssertTrue(sample(idle: 600, agentWorking: true).isPresent)
        XCTAssertFalse(sample(idle: 600, agentWorking: false).isPresent)
        // Still not indefinite: an agent left running overnight proves nothing.
        XCTAssertFalse(sample(idle: 3600, agentWorking: true).isPresent)
    }

    // MARK: Accumulating

    func testDeskTimeAccumulatesOneTickAtATime() {
        var c = clock(start)
        var now = start
        for i in 0..<40 {
            now = start.addingTimeInterval(Double(i) * 15)
            c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: now)
        }
        XCTAssertEqual(c.desk, 600, accuracy: 0.01)
    }

    private var start: Date { Date(timeIntervalSince1970: 1_757_400_000) }
    private func clock(_ at: Date) -> WorkClock { WorkClock(day: Calendar.current.startOfDay(for: at)) }

    /// The failure this guards: the timer does not fire while the machine is
    /// asleep, so the first tick after a closed lid reports the whole night.
    /// Reported from a real morning: the lid had been closed all night, the
    /// desk total correctly read four minutes, and the sitting stretch read
    /// 9h11m. The clamp guarded the total; nothing guarded the stretch.
    func testAClosedLidDoesNotLeaveLastNightsStretchRunning() {
        var c = clock(start)
        // An evening at the desk.
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15,
                              now: start.addingTimeInterval(15))
        XCTAssertNotNil(c.sittingSince)

        // The machine sleeps. No tick happens for nine hours — that is the
        // whole point: the absence branch never runs.
        let morning = start.addingTimeInterval(9 * 3600)
        c = WorkClock.advance(c, sample: sample(), elapsed: 9 * 3600, now: morning)

        XCTAssertEqual(c.sitting(at: morning), 0, accuracy: 0.01)
        XCTAssertEqual(c.sittingSince, morning)
        // Two evening ticks of fifteen seconds, and the night clamped to one
        // step however long the lid was shut.
        XCTAssertEqual(c.desk, 30 + WorkClock.maxStep, accuracy: 0.01)
    }

    /// The gap rule must not fire on an ordinary late tick — a busy machine
    /// delivers timers seconds late, and that is not a rest.
    func testAnOrdinaryLateTickIsNotTreatedAsARest() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        let began = c.sittingSince
        c = WorkClock.advance(c, sample: sample(), elapsed: 70,
                              now: start.addingTimeInterval(70))
        XCTAssertEqual(c.sittingSince, began)
    }

    func testASleepingMachineCannotBankTheNight() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 8 * 3600,
                              now: start.addingTimeInterval(8 * 3600))
        XCTAssertEqual(c.desk, 15 + WorkClock.maxStep, accuracy: 0.01)
    }

    func testTimeIsNotCountedWhileAway() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        c = WorkClock.advance(c, sample: sample(locked: true), elapsed: 15,
                              now: start.addingTimeInterval(15))
        XCTAssertEqual(c.desk, 15, accuracy: 0.01)
    }

    // MARK: The sitting stretch

    func testAShortAbsenceDoesNotUndoTheStretch() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        let began = c.sittingSince
        // Away for two minutes.
        c = WorkClock.advance(c, sample: sample(locked: true), elapsed: 15,
                              now: start.addingTimeInterval(60))
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start.addingTimeInterval(180))
        XCTAssertEqual(c.sittingSince, began)
        XCTAssertNil(c.awaySince)
    }

    func testARealRestStartsTheStretchAgain() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        c = WorkClock.advance(c, sample: sample(locked: true), elapsed: 15,
                              now: start.addingTimeInterval(60))
        let back = start.addingTimeInterval(60 + 6 * 60)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: back)
        XCTAssertEqual(c.sittingSince, back)
        XCTAssertEqual(c.sitting(at: back), 0, accuracy: 0.01)
    }

    /// The stretch must clear itself while you are still away, or the app tells
    /// you that you have been sitting for four hours when you left after one.
    func testTheStretchClearsWhileStillAway() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(), elapsed: 15, now: start)
        c = WorkClock.advance(c, sample: sample(locked: true), elapsed: 15,
                              now: start.addingTimeInterval(60))
        XCTAssertNotNil(c.sittingSince)
        c = WorkClock.advance(c, sample: sample(locked: true), elapsed: 15,
                              now: start.addingTimeInterval(60 + 400))
        XCTAssertNil(c.sittingSince)
    }

    // MARK: Midnight

    func testTotalsResetAtMidnightButTheStretchDoesNot() {
        let calendar = Calendar.current
        let beforeMidnight = calendar.date(bySettingHour: 23, minute: 40, second: 0, of: start)!
        var c = clock(beforeMidnight)
        c = WorkClock.advance(c, sample: sample(), elapsed: 60, now: beforeMidnight)
        let began = c.sittingSince
        XCTAssertEqual(c.desk, 60, accuracy: 0.01)

        let afterMidnight = beforeMidnight.addingTimeInterval(30 * 60)
        c = WorkClock.advance(c, sample: sample(), elapsed: 60, now: afterMidnight)
        XCTAssertEqual(c.desk, 60, accuracy: 0.01)          // today's total, not yesterday's
        XCTAssertEqual(c.sittingSince, began)                // fifty minutes of sitting
        XCTAssertEqual(c.sitting(at: afterMidnight), 30 * 60, accuracy: 1)
    }
}
