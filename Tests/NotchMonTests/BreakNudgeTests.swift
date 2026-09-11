import XCTest
@testable import NotchMon

@MainActor
final class BreakLadderTests: XCTestCase {

    func testTheLadderIsTheEvidence() {
        // 30 is the finding, 60 is where the regulators stop being vague, 90 is
        // where the app already drew its line, and two hours is the point at
        // which the quieter sizes have been ignored twice.
        XCTAssertEqual(BreakLadder.steps.map(\.after), [1800, 3600, 5400, 7200])
        XCTAssertEqual(BreakLadder.steps.map(\.level), [.inline, .pill, .pill, .panel])
    }

    func testARungIsReachedOnItsBoundaryNotAfterIt() {
        XCTAssertNil(BreakLadder.step(at: 1799))
        XCTAssertEqual(BreakLadder.step(at: 1800)?.after, 1800)
        XCTAssertEqual(BreakLadder.step(at: 3599)?.after, 1800)
        XCTAssertEqual(BreakLadder.step(at: 3600)?.after, 3600)
        // Past the top rung it stays on the top rung rather than going quiet.
        XCTAssertEqual(BreakLadder.step(at: 60 * 3600)?.after, 7200)
    }

    func testTheSameSeedAlwaysPicksTheSamePicture() {
        let hour = BreakLadder.steps[1]
        XCTAssertEqual(BreakLadder.sprite(for: hour, seed: 3).id,
                       BreakLadder.sprite(for: hour, seed: 3).id)
        // And it moves on, so it is not coffee every hour of every day.
        XCTAssertNotEqual(BreakLadder.sprite(for: hour, seed: 3).id,
                          BreakLadder.sprite(for: hour, seed: 4).id)
        // A negative seed cannot reach outside the pool.
        XCTAssertNotNil(BreakLadder.sprite(for: hour, seed: -7).id)
    }

    func testTheMarkSaysNothingUntilTheFirstRung() {
        XCTAssertNil(BreakLadder.mark(at: 10 * 60, eyes: false, seed: 0))
        XCTAssertNil(BreakLadder.mark(at: 29 * 60, eyes: false, seed: 0))
        XCTAssertEqual(BreakLadder.mark(at: 30 * 60, eyes: false, seed: 0)?.id, "stretch")
    }

    func testTheEyeReminderIsOnlyOfferedNotImposed() {
        // Off, twenty minutes is silent.
        XCTAssertNil(BreakLadder.mark(at: 21 * 60, eyes: false, seed: 0))
        XCTAssertEqual(BreakLadder.mark(at: 21 * 60, eyes: true, seed: 0)?.id, "eyes")
        // And it never outranks a real rung.
        XCTAssertEqual(BreakLadder.mark(at: 40 * 60, eyes: true, seed: 0)?.id, "stretch")
    }
}

@MainActor
final class NudgeCenterTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func centre() -> NudgeCenter { NudgeCenter() }

    private func run(_ centre: NudgeCenter, sitting: TimeInterval,
                     since: Date? = nil, at offset: TimeInterval = 0,
                     enabled: Bool = true, ceiling: NudgeLevel = .panel, eyes: Bool = false) {
        centre.advance(sitting: sitting, since: since ?? start,
                       now: start.addingTimeInterval(offset),
                       enabled: enabled, ceiling: ceiling, eyes: eyes)
    }

    func testARungFiresOnceInAStretch() {
        let c = centre()
        run(c, sitting: 3600)
        XCTAssertEqual(c.active?.level, .pill)
        let first = c.active

        // Three seconds later, still sitting, still past the hour. Inside the
        // window, because the window is a few seconds — the tick is fifteen,
        // which is exactly why the expiry has a clock of its own.
        run(c, sitting: 3603, at: 3)
        XCTAssertEqual(c.active, first, "the same nudge, not a second one")

        // Once it has expired it does not come back for the same rung.
        run(c, sitting: 3900, at: 300)
        XCTAssertNil(c.active)
    }

    func testANewSitClearsWhatHasFired() {
        let c = centre()
        run(c, sitting: 3600)
        XCTAssertNotNil(c.active)

        // Up for a coffee, then back down: a different `sittingSince`.
        let later = start.addingTimeInterval(4000)
        c.advance(sitting: 0, since: later, now: later,
                  enabled: true, ceiling: .panel, eyes: false)
        XCTAssertNil(c.active)
        XCTAssertNil(c.mark, "a fresh sit has nothing to say yet")

        c.advance(sitting: 3600, since: later, now: later.addingTimeInterval(3600),
                  enabled: true, ceiling: .panel, eyes: false)
        XCTAssertNotNil(c.active, "the hour comes round again in the new stretch")
    }

    func testTheCeilingCapsTheNoiseWithoutStoringUpTheLadder() {
        let c = centre()
        // Capped at the mark: the hour changes the strip and opens nothing.
        run(c, sitting: 3600, ceiling: .inline)
        XCTAssertNil(c.active)
        XCTAssertNotNil(c.mark, "the mark still carries it")

        // Raising the ceiling later must not fire the whole ladder at once —
        // the rung was reached, whatever it was allowed to do about it.
        run(c, sitting: 3700, at: 100, ceiling: .panel)
        XCTAssertNil(c.active)
    }

    func testThePanelRungIsCappedToThePillWhenAsked() {
        let c = centre()
        run(c, sitting: 7200, ceiling: .pill)
        XCTAssertEqual(c.active?.level, .pill, "loud, but never the panel")
    }

    func testTheTwoHourRungAsksForThePanel() {
        let c = centre()
        run(c, sitting: 7200)
        XCTAssertEqual(c.active?.level, .panel)
        XCTAssertTrue(["game", "book", "window"].contains(c.active?.sprite.id ?? ""))
    }

    func testANudgeStaysLongEnoughToBeCaught() {
        let c = centre()
        run(c, sitting: 3600)
        // It was three loops of the sprite — seven seconds — and ninety
        // one-second captures of a real sit caught the notch open in seven
        // frames. Nobody sees seven seconds at the top edge of a screen they
        // are not looking at.
        XCTAssertEqual(c.active?.until.timeIntervalSince(start), 30)
        run(c, sitting: 3620, at: 20)
        XCTAssertNotNil(c.active, "still up twenty seconds later")
        run(c, sitting: 3700, at: 100)
        XCTAssertNil(c.active, "and gone without being dismissed")
    }

    func testThePanelGetsLessPatienceThanTheNotch() {
        let c = centre()
        run(c, sitting: 7200)
        XCTAssertEqual(c.active?.until.timeIntervalSince(start), 15,
                       "it is the whole top of the screen")
    }

    func testSwitchingItOffStopsEverything() {
        let c = centre()
        run(c, sitting: 3600)
        XCTAssertNotNil(c.active)

        run(c, sitting: 3660, at: 60, enabled: false)
        XCTAssertNil(c.active)
        XCTAssertNil(c.mark, "the mark goes quiet too, not just the pill")
    }

    func testTheMarkAndThePillAgreeOnWhatTheyAreAskingFor() {
        let c = centre()
        run(c, sitting: 3600)
        XCTAssertEqual(c.mark?.id, c.active?.sprite.id,
                       "the pill is the mark said out loud, not a second suggestion")
    }

    func testTheDetailQuotesTheRealFigure() {
        let c = centre()
        run(c, sitting: 95 * 60)
        XCTAssertEqual(c.active?.detail, "1h35m without a break")
    }
}

@MainActor
final class PixelSpriteTimingTests: XCTestCase {

    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func frame(_ seconds: Double, hold: Double) -> Int {
        PixelSprite.index(at: epoch.addingTimeInterval(seconds),
                          frames: 4, cycle: 2.0, hold: hold)
    }

    func testWithNoHoldItRunsStraightThrough() {
        XCTAssertEqual(frame(0.0, hold: 0), 0)
        XCTAssertEqual(frame(0.5, hold: 0), 1)
        XCTAssertEqual(frame(1.5, hold: 0), 3)
        XCTAssertEqual(frame(2.0, hold: 0), 0, "and round again")
    }

    func testAHoldRunsOncePerPeriodAndSitsStill() {
        // One pass over two seconds, then still for forty.
        XCTAssertEqual(frame(0.5, hold: 40), 1)
        XCTAssertEqual(frame(1.5, hold: 40), 3)
        for still in stride(from: 2.0, to: 42.0, by: 3.0) {
            XCTAssertEqual(frame(still, hold: 40), 0, "still at \(still)s")
        }
        XCTAssertEqual(frame(42.5, hold: 40), 1, "and moves again on the next period")
    }

    func testASingleFrameNeverIndexesPastItself() {
        XCTAssertEqual(PixelSprite.index(at: epoch.addingTimeInterval(99),
                                         frames: 1, cycle: 2, hold: 40), 0)
    }

    func testAMarkAnnouncesItselfForThreeLoopsThenSettles() {
        let arrived = Date(timeIntervalSince1970: 1_000_000)
        // coffee's cycle is 1.9s, so three loops is 5.7.
        XCTAssertTrue(BreakLadder.announcing(.coffee, since: arrived,
                                             now: arrived.addingTimeInterval(5)))
        XCTAssertFalse(BreakLadder.announcing(.coffee, since: arrived,
                                              now: arrived.addingTimeInterval(6)))
    }
}

@MainActor
final class NudgeOverATwoHourSitTests: XCTestCase {

    /// The presence monitor ticks every fifteen seconds. Every test above calls
    /// `advance` two or three times by hand, which is not the same thing: it
    /// cannot catch anything that only goes wrong on the four-hundredth call.
    func testEveryRungFiresAcrossARealTwoHourSit() {
        let centre = NudgeCenter()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var raised: [(minute: Int, id: String, level: NudgeLevel)] = []
        var seen: String?

        for tick in 0...(120 * 4) {          // 15s apart, two hours
            let now = start.addingTimeInterval(Double(tick) * 15)
            centre.advance(sitting: now.timeIntervalSince(start), since: start, now: now,
                           enabled: true, ceiling: .panel, eyes: false)
            if let up = centre.active, up.id != seen {
                raised.append((tick * 15 / 60, up.sprite.id, up.level))
            }
            seen = centre.active?.id
        }

        XCTAssertEqual(raised.map(\.minute), [60, 90, 120],
                       "one at the hour, one at ninety minutes, one at two hours")
        XCTAssertEqual(raised.map(\.level), [.pill, .pill, .panel])
    }
}
