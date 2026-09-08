import XCTest
@testable import NotchMon

/// The fold is pure arithmetic with three empirical constants and two
/// deliberate asymmetries. Both asymmetries look like oversights, so each one
/// is pinned here: a future tidy-up that "fixes" them fails loudly instead of
/// quietly deleting the signal they carry.
final class QuotaTrendTests: XCTestCase {

    private let hour: TimeInterval = 3_600

    /// A window five hours long, ending `endsIn` from now.
    private func bounds(endsIn: TimeInterval, length: TimeInterval)
        -> (start: Date, end: Date, now: Date) {
        let now = Date()
        let end = now.addingTimeInterval(endsIn)
        return (end.addingTimeInterval(-length), end, now)
    }

    private func samples(_ points: [(minutesAgo: Double, used: Double)], resetAt: Date, now: Date)
        -> [QuotaSample] {
        points.map {
            QuotaSample(
                at: now.addingTimeInterval(-$0.minutesAgo * 60),
                usedPercent: $0.used,
                resetAt: resetAt)
        }
    }

    // MARK: The minimum-sample floor

    func testOneSampleProducesNoTrendRatherThanZero() {
        let b = bounds(endsIn: hour, length: 5 * hour)
        let trend = QuotaTrendFold.trend(
            usedPercent: 40,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples([(minutesAgo: 5, used: 40)], resetAt: b.end, now: b.now))
        // Nil, not a flat trend at zero: one point cannot have a slope, and
        // drawing "not moving" would be an assertion nothing supports.
        XCTAssertNil(trend)
    }

    func testEmptyHistoryProducesNoTrend() {
        let b = bounds(endsIn: hour, length: 5 * hour)
        XCTAssertNil(QuotaTrendFold.trend(
            usedPercent: 40, windowStart: b.start, windowEnd: b.end, now: b.now, samples: []))
    }

    // MARK: Direction

    func testUntouchedWindowReadsFlatNotBurning() {
        // The case the flat threshold exists for: a window sitting well used
        // because of activity days ago, with no recent movement at all. Its
        // lifetime average says "busy"; its recent slope is zero.
        let b = bounds(endsIn: 2 * hour, length: 7 * 24 * hour)
        let trend = QuotaTrendFold.trend(
            usedPercent: 63,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples(
                [(minutesAgo: 600, used: 63), (minutesAgo: 300, used: 63), (minutesAgo: 10, used: 63)],
                resetAt: b.end, now: b.now))
        XCTAssertEqual(trend?.direction, .flat)
        XCTAssertEqual(trend?.projectedUsedPercent ?? 0, 63, accuracy: 0.001)
        XCTAssertFalse(trend?.runsOutEarly ?? true)
    }

    func testRisingUsageIsDetected() {
        let b = bounds(endsIn: 2.5 * hour, length: 5 * hour)
        let trend = QuotaTrendFold.trend(
            usedPercent: 50,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples(
                [(minutesAgo: 60, used: 30), (minutesAgo: 5, used: 50)],
                resetAt: b.end, now: b.now))
        XCTAssertEqual(trend?.direction, .rising)
        XCTAssertGreaterThan(trend?.projectedUsedPercent ?? 0, 50)
    }

    // MARK: The two asymmetric clamps

    func testProjectionHasNoCeilingBecauseThatIsTheSignal() {
        // Burning a five-hour window fast, halfway through it. The projection
        // must be allowed past 100 — `runsOutEarly` IS `projected > 100`, so a
        // ceiling here would delete the only actionable state the fold has.
        let b = bounds(endsIn: 2.5 * hour, length: 5 * hour)
        let trend = QuotaTrendFold.trend(
            usedPercent: 70,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples(
                [(minutesAgo: 60, used: 30), (minutesAgo: 1, used: 70)],
                resetAt: b.end, now: b.now))
        XCTAssertGreaterThan(trend?.projectedUsedPercent ?? 0, 100)
        XCTAssertTrue(trend?.runsOutEarly ?? false)
        XCTAssertNotNil(trend?.timeToExhaustion)
    }

    func testProjectionHasAFloorSoAProviderCorrectionCannotGoNegative() {
        // A provider revising itself sharply downward. Without the floor this
        // projects below zero and prints a drop larger than the amount that
        // exists.
        let b = bounds(endsIn: 4 * hour, length: 5 * hour)
        let trend = QuotaTrendFold.trend(
            usedPercent: 10,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples(
                [(minutesAgo: 30, used: 90), (minutesAgo: 1, used: 10)],
                resetAt: b.end, now: b.now))
        XCTAssertEqual(trend?.direction, .falling)
        XCTAssertGreaterThanOrEqual(trend?.projectedUsedPercent ?? -1, 0)
    }

    func testDeltaAlwaysAgreesWithTheProjectionBesideIt() {
        // A reader adding the delta to the current reading must land exactly on
        // the projection printed next to it — which is why the delta is
        // recomputed from the clamped value rather than kept raw.
        let b = bounds(endsIn: 4 * hour, length: 5 * hour)
        let used = 10.0
        let trend = QuotaTrendFold.trend(
            usedPercent: used,
            windowStart: b.start, windowEnd: b.end, now: b.now,
            samples: samples(
                [(minutesAgo: 30, used: 90), (minutesAgo: 1, used: 10)],
                resetAt: b.end, now: b.now))
        let t = try? XCTUnwrap(trend)
        XCTAssertEqual(
            (t?.projectedUsedPercent ?? 0),
            used + (t?.projectedDeltaPercent ?? 0),
            accuracy: 0.0001)
    }

    // MARK: Exhaustion time

    func testAWindowThatSurvivesToResetHasNoExhaustionTime() {
        // "Never" must not become a very large number, or it could be ordered
        // against windows that genuinely do run out.
        let trend = QuotaTrend(
            direction: .rising, projectedUsedPercent: 92,
            projectedDeltaPercent: 12, timeToReset: 4 * hour)
        XCTAssertNil(trend.timeToExhaustion)
    }

    func testExhaustionTimeIsTheFractionOfTheRemainingSpan() {
        // 60% used now, projected to 120% by a reset ten hours away: the 40
        // points of headroom are two thirds of the 60 points the rate will
        // spend, so it runs dry two thirds of the way through.
        let trend = QuotaTrend(
            direction: .rising, projectedUsedPercent: 120,
            projectedDeltaPercent: 60, timeToReset: 10 * hour)
        XCTAssertEqual(trend.timeToExhaustion ?? 0, (40.0 / 60.0) * 10 * hour, accuracy: 1)
    }
}

/// The bug this whole change exists to fix: `headline` compared `usedPercent`
/// across windows that share no scale.
final class HeadlineSelectionTests: XCTestCase {

    private let hour: TimeInterval = 3_600

    private func metric(_ label: String, used: Double, resetsIn: TimeInterval) -> UsageMetric {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return UsageMetric(
            label: label, usedPercent: used, remainingPercent: 100 - used,
            remainingLabel: nil, resetsAt: iso.string(from: Date().addingTimeInterval(resetsIn)))
    }

    private func snapshot(_ metrics: [UsageMetric], trends: [String: QuotaTrend]) -> ProviderSnapshot {
        var s = ProviderSnapshot(
            provider: "Claude", plan: "Max 20x", email: nil, metrics: metrics,
            freeResets: 0, seenAt: Date(), isStale: false)
        s.trends = trends
        return s
    }

    func testTheWindowRunningOutSoonestWinsEvenWhenItIsNotTheFullest() {
        let session = metric("5-hour", used: 60, resetsIn: hour)
        let weekly = metric("7-day", used: 84, resetsIn: 4 * 24 * hour)

        // The session is the lower reading and the more urgent window: at this
        // rate it is gone in about forty minutes, while the weekly — despite
        // being fuller — is not on course to run out at all.
        let s = snapshot([session, weekly], trends: [
            "5-hour": QuotaTrend(
                direction: .rising, projectedUsedPercent: 130,
                projectedDeltaPercent: 70, timeToReset: hour),
            "7-day": QuotaTrend(
                direction: .rising, projectedUsedPercent: 88,
                projectedDeltaPercent: 4, timeToReset: 4 * 24 * hour)
        ])

        XCTAssertEqual(s.headline?.label, "5-hour")
        XCTAssertTrue(s.headlineRunsOutEarly)
    }

    func testSoonestExhaustionWinsBetweenTwoWindowsThatBothRunOut() {
        let session = metric("5-hour", used: 60, resetsIn: 4 * hour)
        let weekly = metric("7-day", used: 90, resetsIn: 2 * hour)
        let s = snapshot([session, weekly], trends: [
            // Runs dry in 4h * (40/60) ≈ 2h40m.
            "5-hour": QuotaTrend(
                direction: .rising, projectedUsedPercent: 120,
                projectedDeltaPercent: 60, timeToReset: 4 * hour),
            // Runs dry in 2h * (10/40) = 30m.
            "7-day": QuotaTrend(
                direction: .rising, projectedUsedPercent: 130,
                projectedDeltaPercent: 40, timeToReset: 2 * hour)
        ])
        XCTAssertEqual(s.headline?.label, "7-day")
    }

    func testWithNoProjectionsItFallsBackToTheFullestWindow() {
        // Nothing is on course to run out, so nothing is urgent and the choice
        // stops mattering — the fullest window is what a reader expects.
        let s = snapshot(
            [metric("5-hour", used: 60, resetsIn: hour),
             metric("7-day", used: 84, resetsIn: 4 * 24 * hour)],
            trends: [:])
        XCTAssertEqual(s.headline?.label, "7-day")
        XCTAssertFalse(s.headlineRunsOutEarly)
    }

    func testAnUnfundedWindowNeverWins() {
        // Copilot reports Chat as `0/0 left` on Individual: spent by definition,
        // and letting it win would peg the ring at empty for an untouched
        // account.
        let chat = UsageMetric(
            label: "Chat", usedPercent: 0, remainingPercent: 100,
            remainingLabel: "0/0 left", resetsAt: nil)
        let premium = metric("Premium", used: 12, resetsIn: 22 * 24 * hour)
        let s = snapshot([chat, premium], trends: [:])
        XCTAssertEqual(s.headline?.label, "Premium")
    }
}

final class QuotaDurationTests: XCTestCase {

    private func seconds(_ label: String) -> TimeInterval? {
        QuotaHistory.contractDuration(label: label)?.seconds
    }

    func testTheLabelsTheseVendorsActuallyUse() {
        XCTAssertEqual(seconds("5-hour"), 5 * 3_600)
        XCTAssertEqual(seconds("5h"), 5 * 3_600)
        XCTAssertEqual(seconds("Session"), 5 * 3_600)
        XCTAssertEqual(seconds("Weekly"), 7 * 86_400)
        XCTAssertEqual(seconds("7-day"), 7 * 86_400)
        XCTAssertEqual(seconds("Premium"), 30 * 86_400)
    }

    func testAnUnrecognisedLabelGetsNoDurationRatherThanAGuess() {
        // A guessed duration produces a confidently wrong slope, which is worse
        // than no projection at all.
        XCTAssertNil(seconds("Fable"))
        XCTAssertNil(seconds("credits"))
    }

    func testImplausibleObservedDurationsAreRejected() {
        XCTAssertFalse(QuotaDuration(seconds: 5, source: .observed).isPlausible)
        XCTAssertFalse(QuotaDuration(seconds: 500 * 86_400, source: .observed).isPlausible)
        XCTAssertTrue(QuotaDuration(seconds: 5 * 3_600, source: .observed).isPlausible)
    }
}

/// Admission is by time, not by value. The distinction decides whether a
/// window nobody has touched since morning reads as flat or as burning.
@MainActor
final class QuotaAdmissionTests: XCTestCase {

    /// The fold's own view of a series that stopped moving: a climb, then a
    /// long plateau of repeated readings. If those repeats are dropped the
    /// plateau is invisible and the climb is projected forward for ever.
    func testARepeatedReadingIsWhatMakesASlopeGoFlat() {
        let now = Date()
        let end = now.addingTimeInterval(3_600)
        let start = end.addingTimeInterval(-5 * 3_600)

        func sample(_ minutesAgo: Double, _ used: Double) -> QuotaSample {
            QuotaSample(at: now.addingTimeInterval(-minutesAgo * 60), usedPercent: used, resetAt: end)
        }

        // Climbed to 60 hours ago, then held. The lookback for a 5-hour window
        // is 75 minutes back from the newest sample, so it sees only plateau.
        let held = QuotaTrendFold.trend(
            usedPercent: 60, windowStart: start, windowEnd: end, now: now,
            samples: [sample(200, 20), sample(180, 40), sample(160, 60),
                      sample(60, 60), sample(30, 60), sample(2, 60)])
        XCTAssertEqual(held?.direction, .flat)
        XCTAssertFalse(held?.runsOutEarly ?? true)

        // The same history with the plateau dropped — which is what value-based
        // dedup would have stored. The newest sample is now the top of the
        // climb, and the fold reads a burn that stopped hours ago.
        let deduped = QuotaTrendFold.trend(
            usedPercent: 60, windowStart: start, windowEnd: end, now: now,
            samples: [sample(200, 20), sample(180, 40), sample(160, 60)])
        XCTAssertEqual(deduped?.direction, .rising)
        XCTAssertGreaterThan(
            deduped?.projectedUsedPercent ?? 0, held?.projectedUsedPercent ?? 0,
            "dropping repeated readings preserves a stale slope — the bug this admission rule exists to prevent")
    }
}

/// A reset that moves is not proof a cycle ended.
final class ObservedDurationTests: XCTestCase {

    private let hour: TimeInterval = 3_600

    func testARollingWindowsCreepIsNotAWindowLength() {
        // Codex slides its five-hour reset forward with the clock, so two
        // readings three minutes apart show a three-minute jump. Taking that as
        // the duration measured a five-hour window at one minute.
        XCTAssertNil(QuotaHistory.observedDuration(jump: 60, label: "5h"))
        XCTAssertNil(QuotaHistory.observedDuration(jump: 3 * 60, label: "5-hour"))
        XCTAssertNil(QuotaHistory.observedDuration(jump: 20 * 60, label: "Session"))
    }

    func testARealRolloverIsAccepted() {
        XCTAssertEqual(QuotaHistory.observedDuration(jump: 5 * hour, label: "5-hour"), 5 * hour)
        XCTAssertEqual(QuotaHistory.observedDuration(jump: 7 * 24 * hour, label: "Weekly"), 7 * 24 * hour)
        // Slightly off the nominal length still counts — that is the point of
        // measuring rather than assuming.
        XCTAssertEqual(QuotaHistory.observedDuration(jump: 6.4 * hour, label: "5-hour"), 6.4 * hour)
    }

    func testAWindowWeCannotNameIsNeverObserved() {
        XCTAssertNil(QuotaHistory.observedDuration(jump: 5 * hour, label: "Fable"))
    }

    func testAValueWrittenByAnEarlierBuildIsRejectedOnRead() {
        XCTAssertFalse(QuotaHistory.isCredible(60, label: "5h"))
        XCTAssertTrue(QuotaHistory.isCredible(5 * hour, label: "5h"))
    }
}
