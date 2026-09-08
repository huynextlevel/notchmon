import XCTest
@testable import NotchMon

/// Warning once per window, which is a rule about *crossings*, not about the
/// condition — quotas are polled every few minutes, so a window sitting over
/// the line is over it on every single poll.
final class AlertLedgerTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_800_000_000)

    private func metric(_ label: String, used: Double, resets: Date?) -> UsageMetric {
        UsageMetric(
            label: label, usedPercent: used, remainingPercent: nil, remainingLabel: nil,
            resetsAt: resets.map { ISO8601DateFormatter().string(from: $0) })
    }

    private func provider(_ name: String, _ metrics: [UsageMetric]) -> ProviderSnapshot {
        ProviderSnapshot(provider: name, plan: nil, email: nil, metrics: metrics,
                         freeResets: 0, seenAt: Date(), isStale: false)
    }

    func testCrossingIsReportedOnce() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [metric("Session", used: 80, resets: hour)])

        XCTAssertEqual(ledger.crossings(in: [claude], threshold: 75).count, 1)
        // Same window, still over the line, three more polls.
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 75).isEmpty)
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 75).isEmpty)
    }

    func testBelowTheLineSaysNothing() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [metric("Session", used: 74, resets: hour)])
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 75).isEmpty)
    }

    /// The next window re-arms on its own: it has a different reset instant, so
    /// it has never been warned about. Nothing has to detect that a reset
    /// happened.
    func testANewWindowReArms() {
        var ledger = AlertLedger()
        let first = provider("Claude", [metric("Session", used: 90, resets: hour)])
        XCTAssertEqual(ledger.crossings(in: [first], threshold: 75).count, 1)

        let next = provider("Claude", [metric("Session", used: 90,
                                              resets: hour.addingTimeInterval(5 * 3600))])
        XCTAssertEqual(ledger.crossings(in: [next], threshold: 75).count, 1)
    }

    /// Lowering the threshold is a request to be told about windows already
    /// past the new line — a ledger keyed only by the window would swallow
    /// exactly those.
    func testLoweringTheThresholdReArms() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [metric("Session", used: 80, resets: hour)])
        XCTAssertEqual(ledger.crossings(in: [claude], threshold: 75).count, 1)
        XCTAssertEqual(ledger.crossings(in: [claude], threshold: 50).count, 1)
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 50).isEmpty)
    }

    /// Every metered window counts, not just the session: a weekly limit at 90%
    /// is the one that decides the rest of the week.
    func testEveryMeteredWindowCounts() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [
            metric("Session", used: 80, resets: hour),
            metric("Weekly", used: 95, resets: hour.addingTimeInterval(86_400))
        ])
        XCTAssertEqual(Set(ledger.crossings(in: [claude], threshold: 75).map(\.label)),
                       ["Session", "Weekly"])
    }

    /// A window with no allowance at all — Copilot reports `0/0 left` — is not
    /// a window you can be warned about.
    func testWindowsWithNoAllowanceAreSkipped() {
        var ledger = AlertLedger()
        let empty = UsageMetric(label: "Chat", usedPercent: 0, remainingPercent: nil,
                                remainingLabel: "0/0 left",
                                resetsAt: ISO8601DateFormatter().string(from: hour))
        XCTAssertTrue(ledger.crossings(in: [provider("Copilot", [empty])], threshold: 50).isEmpty)
    }

    /// Without a reset instant there is no way to tell this window from the
    /// next, so "once per window" would silently become "once ever".
    func testAWindowWithNoResetIsSkippedRatherThanWarnedOnce() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [metric("Session", used: 99, resets: nil)])
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 75).isEmpty)
        XCTAssertTrue(ledger.warned.isEmpty)
    }

    func testPruneForgetsWindowsThatHaveAlreadyReset() {
        var ledger = AlertLedger()
        let past = provider("Claude", [metric("Session", used: 90, resets: hour)])
        let future = provider("Codex", [metric("5h", used: 90,
                                               resets: hour.addingTimeInterval(3600))])
        _ = ledger.crossings(in: [past, future], threshold: 75)
        XCTAssertEqual(ledger.warned.count, 2)

        ledger.prune(now: hour.addingTimeInterval(60))
        XCTAssertEqual(ledger.warned.count, 1)
        // And the reset window can be warned about again.
        XCTAssertEqual(ledger.crossings(in: [past], threshold: 75).count, 1)
    }

    func testNonsenseThresholdWarnsAboutNothing() {
        var ledger = AlertLedger()
        let claude = provider("Claude", [metric("Session", used: 99, resets: hour)])
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 0).isEmpty)
        XCTAssertTrue(ledger.crossings(in: [claude], threshold: 101).isEmpty)
    }
}
