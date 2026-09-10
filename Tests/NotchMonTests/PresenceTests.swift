import XCTest
@testable import NotchMon

final class PresenceTests: XCTestCase {

    private func sample(idle: TimeInterval = 0, locked: Bool = false, onConsole: Bool = true,
                        displayOn: Bool = true, agentWorking: Bool = false,
                        agentActive: Bool = false, attending: Bool = true) -> Presence.Sample {
        .init(idle: idle, locked: locked, onConsole: onConsole,
              displayOn: displayOn, agentWorking: agentWorking,
              agentActive: agentActive, attending: attending)
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

    private var start: Date { Date(timeIntervalSince1970: 1_757_400_000) }
    private func clock(_ at: Date) -> WorkClock { WorkClock(day: Calendar.current.startOfDay(for: at)) }

    func testCodingTimeIsAlwaysASubsetOfDeskTime() {
        var c = clock(start)
        var now = start
        for i in 0..<40 {
            now = start.addingTimeInterval(Double(i) * 15)
            c = WorkClock.advance(c, sample: sample(agentActive: i % 4 == 0), elapsed: 15, now: now)
        }
        XCTAssertEqual(c.desk, 600, accuracy: 0.01)
        XCTAssertEqual(c.coding, 150, accuracy: 0.01)
        XCTAssertLessThanOrEqual(c.coding, c.desk)
    }

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

    /// The two are not the same question and must not share an answer.
    ///
    /// `agentWorking` says the machine is producing, and it exists to stretch
    /// how long you may sit still before being counted as gone. `inSession`
    /// says you are inside a piece of work, and it is what makes time coding
    /// time — including the minutes spent reading the answer, when nothing is
    /// working at all.
    func testCodingFollowsTheAgentNotJustTheEditorBeingOpen() {
        var c = clock(start)
        // An agent between tool calls: quiet for a moment, still running.
        c = WorkClock.advance(c, sample: sample(agentWorking: false, agentActive: true),
                              elapsed: 15, now: start)
        XCTAssertEqual(c.coding, 15, accuracy: 0.01)

        // Watching a long build: producing, and still the same session.
        c = WorkClock.advance(c, sample: sample(agentWorking: true, agentActive: true),
                              elapsed: 15, now: start.addingTimeInterval(15))
        XCTAssertEqual(c.coding, 30, accuracy: 0.01)

        // The editor is open and nothing is running — which is most of a day
        // for anyone who leaves it open. Desk time, not coding time.
        c = WorkClock.advance(c, sample: sample(agentWorking: false, agentActive: false, attending: true),
                              elapsed: 15, now: start.addingTimeInterval(30))
        XCTAssertEqual(c.coding, 30, accuracy: 0.01)
        XCTAssertEqual(c.desk, 45, accuracy: 0.01)
    }

    /// The failure this was caught by: an agent wrote to its session file every
    /// few seconds while the frontmost application played a video, and the
    /// clock called it coding to within a minute of the desk time.
    func testAnAgentGrindingWhileYouWatchAVideoIsNotCoding() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(agentActive: true, attending: false),
                              elapsed: 15, now: start)
        XCTAssertEqual(c.desk, 15, accuracy: 0.01)
        XCTAssertEqual(c.coding, 0, accuracy: 0.01)
    }

    /// An editor can sit open all day, so it cannot be the whole test.
    func testAnOpenEditorWithNothingRunningIsNotCoding() {
        var c = clock(start)
        c = WorkClock.advance(c, sample: sample(agentActive: false, attending: true),
                              elapsed: 15, now: start)
        XCTAssertEqual(c.desk, 15, accuracy: 0.01)
        XCTAssertEqual(c.coding, 0, accuracy: 0.01)
    }

    func testTerminalsAndEditorsCountAndBrowsersDoNot() {
        XCTAssertTrue(Presence.isCodingSurface("com.apple.Terminal"))
        XCTAssertTrue(Presence.isCodingSurface("com.mitchellh.ghostty"))
        XCTAssertTrue(Presence.isCodingSurface("com.todesktop.230313mzl4w4u92"))
        // A family, so an edition nobody listed still counts.
        XCTAssertTrue(Presence.isCodingSurface("com.jetbrains.goland"))
        XCTAssertFalse(Presence.isCodingSurface("com.brave.Browser"))
        XCTAssertFalse(Presence.isCodingSurface("com.apple.Safari"))
        XCTAssertFalse(Presence.isCodingSurface(nil))
        XCTAssertFalse(Presence.isCodingSurface(""))
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
