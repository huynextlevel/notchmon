import XCTest
@testable import NotchMon

@MainActor
final class TimeRangeTests: XCTestCase {

    private func day(_ name: String, desk: Double = 3600, longest: Double = 0,
                     hours: [Int: Double] = [:]) -> WorkDay {
        var d = WorkDay(day: name, desk: desk, longestStretch: longest)
        for (h, v) in hours { d.hours[h] = v }
        return d
    }

    private var month: [WorkDay] {
        (1...31).map { day(String(format: "2026-08-%02d", $0)) }
    }

    /// 2026-08-31, so a range ending "today" has a fixed last column.
    private var now: Date {
        WorkHistory.date(forKey: "2026-08-31")!
    }

    func testARangeEndsTodayAndRunsBack() {
        XCTAssertEqual(WorkHistory.days(month, in: .week, now: now).count, 7)
        XCTAssertEqual(WorkHistory.days(month, in: .week, now: now).last?.day, "2026-08-31")
        XCTAssertEqual(WorkHistory.days(month, in: .week, now: now).first?.day, "2026-08-25")
        XCTAssertEqual(WorkHistory.days(month, in: .month, now: now).count, 30)
        XCTAssertEqual(WorkHistory.days(month, in: .today, now: now).map(\.day), ["2026-08-31"])
    }

    func testADayWithNothingRecordedStillGetsAColumn() {
        // Three days at the start of the month, asked for as thirty.
        let sparse = (1...3).map { day(String(format: "2026-08-%02d", $0)) }
        let window = WorkHistory.days(sparse, in: .month, now: now)
        XCTAssertEqual(window.count, 30)
        // The window opens on the 2nd, so the 1st falls outside it entirely.
        XCTAssertEqual(window.count { $0.desk > 0 }, 2)
        XCTAssertEqual(window.first?.day, "2026-08-02")
        XCTAssertEqual(window.last?.day, "2026-08-31")
        // Dropping the empty days would have redrawn a scattered month as a
        // run of consecutive days.
        XCTAssertEqual(window.map(\.day), (2...31).map { String(format: "2026-08-%02d", $0) })
        for day in window where !["2026-08-02", "2026-08-03"].contains(day.day) {
            XCTAssertEqual(day.desk, 0)
        }
    }

    func testEveryRangeIsAFixedNumberOfDays() {
        // An All beside these had no length of its own — one column on the day
        // it was installed, and never twice the same span.
        XCTAssertEqual(TimeRange.allCases.map(\.days), [1, 7, 30])
        // A brand new install still draws the whole window.
        XCTAssertEqual(WorkHistory.days([], in: .month, now: now).count, 30)
        XCTAssertEqual(WorkHistory.days([], in: .month, now: now).allSatisfy { $0.desk == 0 }, true)
    }

    func testAKeyRoundTripsThroughItsDate() {
        let date = WorkHistory.date(forKey: "2026-08-31")
        XCTAssertNotNil(date)
        XCTAssertEqual(WorkHistory.key(for: date!), "2026-08-31")
        XCTAssertNil(WorkHistory.date(forKey: "not-a-day"))
    }

    // MARK: Parts of a day

    func testBandsSplitTheDayIntoFourSixHourWindows() {
        XCTAssertEqual(DayBand.night.hours, 0..<6)
        XCTAssertEqual(DayBand.evening.hours, 18..<24)
        XCTAssertEqual(DayBand.morning.window, "06:00–12:00")
        // Every hour belongs to exactly one band.
        for hour in 0..<24 {
            XCTAssertEqual(DayBand.allCases.count { $0.hours.contains(hour) }, 1, "hour \(hour)")
        }
    }

    func testBandsSumTheHoursTheyCover() {
        let d = day("2026-09-08", desk: 657 * 60,
                    hours: [9: 600, 11: 1560, 13: 3600, 20: 1800])
        let bands = Dictionary(uniqueKeysWithValues:
            WorkHistory.bands(d).map { ($0.band, $0.seconds) })
        XCTAssertEqual(bands[.night], 0)
        XCTAssertEqual(bands[.morning], 2160)      // 09:00 and 11:00
        XCTAssertEqual(bands[.afternoon], 3600)
        XCTAssertEqual(bands[.evening], 1800)
    }

    // MARK: Hit testing

    private let bounds = CGRect(x: 0, y: 0, width: 7 * 10 + 6 * 2, height: 92)

    private func index(atX x: CGFloat, y: CGFloat = 40) -> Int? {
        DayHit.at(CGPoint(x: x, y: y), in: bounds, count: 7, height: 92)?.index
    }

    func testEachBarAnswersForItsOwnDay() {
        XCTAssertEqual(index(atX: 1), 0)
        XCTAssertEqual(index(atX: 9), 0)
        XCTAssertEqual(index(atX: 13), 1)
        XCTAssertEqual(index(atX: bounds.width - 1), 6)
    }

    func testTheGapAndTheOutsideAreNotHits() {
        XCTAssertNil(index(atX: 11))
        XCTAssertNil(index(atX: -1))
        XCTAssertNil(index(atX: bounds.width + 1))
        XCTAssertNil(index(atX: 5, y: 200))
        XCTAssertNil(DayHit.at(.zero, in: bounds, count: 0, height: 92))
    }

    // MARK: Reading the stored key back

    /// The key is this app's own `yyyy-MM-dd`; parsing it through a formatter
    /// would run it past a locale that might disagree with it.
    func testDatesAreReadWithoutAFormatter() {
        let d = day("2026-09-08")
        XCTAssertEqual(DayChart.shortDate(d), "8 Sep")
        XCTAssertEqual(DayChart.longDate(d), "Tue 8 Sep")
        XCTAssertEqual(DayChart.dayNumber(d), "8")
        // Nonsense in, the key back out rather than a crash.
        XCTAssertEqual(DayChart.shortDate(day("not-a-date")), "not-a-date")
    }

    func testMinutesPastMidnightReadAsAClock() {
        XCTAssertEqual(DayChart.time(0), "00:00")
        XCTAssertEqual(DayChart.time(678), "11:18")
        XCTAssertEqual(DayChart.time(1439), "23:59")
    }

    func testMedianIsTakenOverExactlyTheDaysGiven() {
        let days = [day("a", desk: 3600), day("b", desk: 7200), day("c", desk: 36000)]
        XCTAssertEqual(WorkHistory.median(days), 7200, accuracy: 0.1)
        XCTAssertEqual(WorkHistory.median(days.prefix(1)), 3600, accuracy: 0.1)
        XCTAssertEqual(WorkHistory.median([]), 0)
    }
}
