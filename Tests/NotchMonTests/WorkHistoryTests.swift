import XCTest
@testable import NotchMon

@MainActor
final class WorkHistoryTests: XCTestCase {

    private func day(_ name: String, desk: Double,
                     longest: Double = 0, hours: [Int: Double] = [:]) -> WorkDay {
        var d = WorkDay(day: name, desk: desk, longestStretch: longest)
        for (h, v) in hours { d.hours[h] = v }
        return d
    }

    // MARK: The rhythm

    func testRhythmSumsEveryDayInTheWindow() {
        let days = [day("2026-09-01", desk: 100, hours: [9: 60, 21: 40]),
                    day("2026-09-02", desk: 100, hours: [21: 90])]
        let rhythm = WorkHistory.rhythm(days)
        XCTAssertEqual(rhythm[9], 60)
        XCTAssertEqual(rhythm[21], 130)
        XCTAssertEqual(WorkHistory.peakHour(rhythm), 21)
    }

    func testPeakHourIsNilWhenNothingWasRecorded() {
        XCTAssertNil(WorkHistory.peakHour(Array(repeating: 0, count: 24)))
    }

    /// The night band is 22:00–06:00 inclusive of 22 and 23, exclusive of 06.
    func testNightShareCountsTheRightHours() {
        var rhythm = Array(repeating: 0.0, count: 24)
        rhythm[23] = 30; rhythm[5] = 10; rhythm[6] = 60
        XCTAssertEqual(WorkHistory.nightShare(rhythm), 40.0 / 100.0, accuracy: 0.0001)
        XCTAssertTrue(WorkHistory.isNight(22))
        XCTAssertTrue(WorkHistory.isNight(0))
        XCTAssertTrue(WorkHistory.isNight(5))
        XCTAssertFalse(WorkHistory.isNight(6))
        XCTAssertFalse(WorkHistory.isNight(21))
    }

    func testNightShareIsZeroRatherThanNaNWithNoData() {
        XCTAssertEqual(WorkHistory.nightShare(Array(repeating: 0, count: 24)), 0)
    }

    // MARK: The figures under the chart

    func testActiveDaysCountsOnlyDaysWithWork() {
        let days = [day("2026-09-01", desk: 3600), day("2026-09-02", desk: 0),
                    day("2026-09-03", desk: 60)]
        XCTAssertEqual(WorkHistory.activeDays(days), 2)
    }

    func testDaysOverThresholdUsesTheLongestStretchNotTheTotal() {
        // Eight hours at the desk in twenty-minute pieces is not a long stretch.
        let days = [day("2026-09-01", desk: 8 * 3600, longest: 20 * 60),
                    day("2026-09-02", desk: 2 * 3600, longest: 95 * 60)]
        XCTAssertEqual(WorkHistory.daysOverThreshold(days), 1)
    }

    /// The median, because one eleven-hour day drags a mean and leaves the
    /// typical day unstated.
    func testMedianIgnoresDaysWithNothingOnThem() {
        let days = [day("2026-09-01", desk: 0), day("2026-09-02", desk: 3600),
                    day("2026-09-03", desk: 7200), day("2026-09-04", desk: 36000)]
        XCTAssertEqual(WorkHistory.medianDesk(days), 7200, accuracy: 0.1)
    }

    func testLongestStretchNamesItsDayAndIsNilWhenThereIsNone() {
        let days = [day("2026-09-01", desk: 3600, longest: 30 * 60),
                    day("2026-09-02", desk: 3600, longest: 200 * 60)]
        XCTAssertEqual(WorkHistory.longestStretch(days)?.day, "2026-09-02")
        XCTAssertNil(WorkHistory.longestStretch([day("2026-09-01", desk: 3600)]))
    }

    func testTheWindowIsTheLastThirtyDaysNotEverythingKept() {
        let days = (1...60).map { day(String(format: "2026-01-%02d", $0), desk: 3600) }
        XCTAssertEqual(WorkHistory.activeDays(days), WorkHistory.windowDays)
    }

    func testDayKeyIsLocalAndZeroPadded() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 7
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(WorkHistory.key(for: date), "2026-03-07")
    }

    // MARK: Thresholds

    func testTheReadoutEscalatesAtSixtyAndNinetyMinutes() {
        XCTAssertEqual(StretchTone.of(59 * 60), .calm)
        XCTAssertEqual(StretchTone.of(60 * 60), .warn)
        XCTAssertEqual(StretchTone.of(89 * 60), .warn)
        XCTAssertEqual(StretchTone.of(90 * 60), .over)
    }

    func testGaugeFillIsClampedPastTheThreshold() {
        XCTAssertEqual(Presence.toward(45 * 60), 0.5, accuracy: 0.001)
        XCTAssertEqual(Presence.toward(180 * 60), 1)
        XCTAssertEqual(Presence.toward(-5), 0)
    }

    // MARK: Formatting

    func testDurationsReadAsClocksNotSeconds() {
        XCTAssertEqual(TimeInterval(47 * 60).clockText, "47m")
        XCTAssertEqual(TimeInterval(3600 + 47 * 60).clockText, "1h47m")
        // Zero-padded minutes, or "1h7m" and "1h47m" are different widths and
        // the strip twitches every hour.
        XCTAssertEqual(TimeInterval(3600 + 7 * 60).clockText, "1h07m")
        XCTAssertEqual(TimeInterval(0).clockText, "0m")
    }

    /// Reported as hard to read: a short day's longest stretch showed as
    /// "0.6h". Nobody thinks in tenths of an hour.
    func testUnderAnHourReadsAsMinutes() {
        func text(_ seconds: TimeInterval) -> String {
            let parts = seconds.figureAndUnit
            return parts.figure + parts.unit
        }
        XCTAssertEqual(text(36 * 60), "36m")
        XCTAssertEqual(text(59 * 60), "59m")
        XCTAssertEqual(text(0), "0m")
        // And over it, hours and minutes — never 2.5h.
        XCTAssertEqual(text(60 * 60), "1h00m")
        XCTAssertEqual(text(2.5 * 3600), "2h30m")
        XCTAssertEqual(text(9 * 3600 + 11 * 60), "9h11m")
    }

    /// The figure and its unit split so the unit can be set smaller beside a
    /// large number, and the two halves must always rejoin into `clockText`.
    func testTheSplitAgreesWithTheSingleString() {
        for seconds in [0.0, 59, 61, 600, 3599, 3600, 3661, 40_000] {
            let parts = TimeInterval(seconds).figureAndUnit
            XCTAssertEqual(parts.figure + parts.unit, TimeInterval(seconds).clockText)
        }
    }
}

@MainActor
final class WorkHistoryGuardTests: XCTestCase {

    /// A stretch cannot be longer than the day it happened on. The overnight
    /// bug wrote 9h11m onto a day with fifty minutes of desk time, and the
    /// figure would have stayed on the chart forever.
    func testAStretchLongerThanTheDayIsRefused() {
        let history = WorkHistory.shared
        let before = history.days.last?.longestStretch ?? 0
        history.record(desk: 60, stretch: 9 * 3600, at: Date())
        let after = history.days.last
        XCTAssertNotNil(after)
        XCTAssertLessThanOrEqual(after!.longestStretch, after!.desk)
        XCTAssertGreaterThanOrEqual(after!.longestStretch, before)
    }
}

@MainActor
final class TodayLookupTests: XCTestCase {

    /// The panel says "at the desk today", so the clock has to be told what
    /// today already holds. Without this it read "since this app started" —
    /// 19 minutes on screen against 73 in the file.
    func testTodayFindsTheRowForNowAndNothingElse() {
        let history = WorkHistory.shared
        history.record(desk: 30, stretch: 30, at: Date())
        let today = history.today()
        XCTAssertNotNil(today)
        XCTAssertEqual(today?.day, WorkHistory.key(for: Date()))
        XCTAssertGreaterThanOrEqual(today?.desk ?? 0, 30)

        // Yesterday is a different row and must not be picked up.
        let yesterday = Date().addingTimeInterval(-24 * 3600)
        XCTAssertNotEqual(history.today(yesterday)?.day, today?.day)
    }
}

@MainActor
final class RhythmHitTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 24 * 10 + 23 * 2, height: 92)

    private func hour(atX x: CGFloat, y: CGFloat = 40) -> Int? {
        RhythmHit.at(CGPoint(x: x, y: y), in: bounds, height: 92)?.hour
    }

    func testEachColumnAnswersForItsOwnHour() {
        XCTAssertEqual(hour(atX: 1), 0)
        XCTAssertEqual(hour(atX: 9), 0)
        // Second column starts one pitch in: ten points of bar plus a two-point
        // gap.
        XCTAssertEqual(hour(atX: 13), 1)
        XCTAssertEqual(hour(atX: bounds.width - 1), 23)
    }

    /// A card that appeared while the pointer sat in a gap would be naming an
    /// hour the pointer is not on — the same rule the activity grid follows.
    func testTheGapBetweenColumnsIsNotAHit() {
        XCTAssertNil(hour(atX: 11))
    }

    func testOutsideTheChartIsNothing() {
        XCTAssertNil(hour(atX: -1))
        XCTAssertNil(hour(atX: bounds.width + 1))
        XCTAssertNil(hour(atX: 5, y: -1))
        XCTAssertNil(hour(atX: 5, y: 200))
    }

    func testAZeroWidthChartCannotBeDivided() {
        XCTAssertNil(RhythmHit.at(.zero, in: .zero, height: 92))
    }
}
