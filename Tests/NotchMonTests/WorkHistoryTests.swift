import XCTest
@testable import NotchMon

@MainActor
final class WorkHistoryTests: XCTestCase {

    private func day(_ name: String, desk: Double, coding: Double = 0,
                     longest: Double = 0, hours: [Int: Double] = [:]) -> WorkDay {
        var d = WorkDay(day: name, desk: desk, coding: coding, longestStretch: longest)
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
        XCTAssertEqual(TimeInterval(5.6 * 3600).hoursText, "5.6h")
    }
}
