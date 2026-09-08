import XCTest
@testable import NotchMon

/// Who gets a dial and who gets a chip.
///
/// The dial section held two agents and was never asked to hold ten. It does
/// not fail on width — three columns still carry the second line — it fails on
/// height: ten rich dials is four rows, and four rows adds about 220 points to
/// a panel already 350 tall and hanging off a notch.
final class OverviewRosterTests: XCTestCase {
    private func agent(_ name: String, left: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: name, plan: nil, email: nil,
            metrics: [UsageMetric(label: "5-hour", usedPercent: 100 - left,
                                  remainingPercent: left, remainingLabel: nil, resetsAt: nil)],
            freeResets: 0, seenAt: Date(), isStale: false)
    }

    /// The counts that actually occur on a desk are untouched: every agent
    /// keeps its dial and no roster appears at all.
    func testThreeOrFewerAreAllHeadline() {
        for count in 1...3 {
            let agents = (0..<count).map { agent("a\($0)", left: Double($0 * 10)) }
            let split = OverviewRoster.split(agents)
            XCTAssertEqual(split.headline.count, count)
            XCTAssertTrue(split.roster.isEmpty)
        }
    }

    /// The case this exists for.
    func testTenAgentsBecomeThreeDialsAndSevenChips() {
        let agents = (0..<10).map { agent("a\($0)", left: Double($0 * 9)) }
        let split = OverviewRoster.split(agents)
        XCTAssertEqual(split.headline.count, 3)
        XCTAssertEqual(split.roster.count, 7)
    }

    /// The headline is the point: whatever is closest to running out leads,
    /// wherever it arrived in the list.
    func testTheEmptiestLeadsWhereverItArrived() {
        let split = OverviewRoster.split([
            agent("full", left: 100),
            agent("fine", left: 62),
            agent("nearly gone", left: 4),
            agent("low", left: 12)
        ])
        XCTAssertEqual(split.headline.map(\.provider), ["nearly gone", "low", "fine"])
        XCTAssertEqual(split.roster.map(\.provider), ["full"])
    }

    /// Stability matters more than it looks: several agents sitting at 100% is
    /// the ordinary case on a machine with ten of them, and they must not trade
    /// places every time the quota poll lands.
    func testAgentsOnTheSameFigureKeepAStableOrder() {
        let agents = [agent("zed", left: 100), agent("amp", left: 100), agent("qwen", left: 100)]
        XCTAssertEqual(OverviewRoster.split(agents).headline.map(\.provider),
                       ["amp", "qwen", "zed"])
        XCTAssertEqual(OverviewRoster.split(agents.reversed()).headline.map(\.provider),
                       ["amp", "qwen", "zed"])
    }

    /// An agent that reports no metered window at all reads as full rather than
    /// as empty — otherwise a provider that simply says nothing would take the
    /// headline away from one that is genuinely about to run out.
    func testAnAgentWithNoWindowIsNotTreatedAsEmpty() {
        let silent = ProviderSnapshot(provider: "silent", plan: nil, email: nil, metrics: [],
                                      freeResets: 0, seenAt: Date(), isStale: false)
        let split = OverviewRoster.split([silent, agent("low", left: 9)])
        XCTAssertEqual(split.headline.first?.provider, "low")
    }
}
