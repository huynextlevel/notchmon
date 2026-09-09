import XCTest
import NotchMonBridge
@testable import NotchMon

@MainActor
final class SessionResolveTests: XCTestCase {

    private func session(_ id: String, _ agent: String, _ status: SessionStatus,
                         workspace: String? = nil, ago: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: agent, status: status, workspace: workspace,
                     model: nil, tool: nil, tty: nil, pid: nil,
                     updated: Date().addingTimeInterval(-ago))
    }

    // MARK: Precedence

    func testFileWatcherSpeaksOnlyForBrandsWithNoReport() {
        let watched: [Brand: ActivityLevel] = [.claude: .lively, .gemini: .settling]
        let hook = [session("a", "claude", .waiting)]

        // Claude reported, and reported that it is waiting: the file saying
        // "lively" is the disagreement this layer exists to settle.
        XCTAssertNil(SessionResolve.level(for: .claude, hook: hook, watched: watched))
        // Gemini said nothing, so the watcher still answers for it.
        XCTAssertEqual(SessionResolve.level(for: .gemini, hook: hook, watched: watched), .settling)
    }

    func testLiveliestSessionSpeaksForTheBrand() {
        let hook = [session("a", "claude", .compacting), session("b", "claude", .working)]
        XCTAssertEqual(SessionResolve.level(for: .claude, hook: hook, watched: [:]), .lively)
    }

    func testCompactingIsSettlingAndWaitingIsStill() {
        XCTAssertEqual(SessionResolve.level(for: .compacting), .settling)
        XCTAssertEqual(SessionResolve.level(for: .working), .lively)
        XCTAssertNil(SessionResolve.level(for: .waiting))
        XCTAssertNil(SessionResolve.level(for: .ended))
    }

    // MARK: The baton

    func testNoBatonWhenNothingIsWaiting() {
        XCTAssertNil(SessionResolve.baton([session("a", "claude", .working),
                                           session("b", "gemini", .compacting)]))
    }

    func testBatonNamesTheLongestWaitingSession() {
        let list = [session("new", "claude", .waiting, workspace: "/Users/x/recent", ago: 10),
                    session("old", "gemini", .waiting, workspace: "/Users/x/forgotten", ago: 600),
                    session("run", "claude", .working)]
        let baton = SessionResolve.baton(list)
        XCTAssertEqual(baton?.title, "forgotten")
        XCTAssertEqual(baton?.others, 1)
    }

    func testBatonCountsOnlyTheOthersWaiting() {
        let one = SessionResolve.baton([session("a", "claude", .waiting, workspace: "/p/one")])
        XCTAssertEqual(one?.others, 0)
    }

    // MARK: Titles

    func testTitleIsTheProjectNotTheTool() {
        let s = session("a", "claude", .waiting, workspace: "/Users/x/Desktop/projects/notchmon")
        XCTAssertEqual(SessionResolve.title(for: s), "notchmon")
    }

    func testTitleFallsBackToTheToolWhenThereIsNoWorkspace() {
        XCTAssertEqual(SessionResolve.title(for: session("a", "gemini", .waiting)), "Gemini CLI")
        XCTAssertEqual(SessionResolve.title(for: session("b", "claude", .waiting, workspace: "  ")),
                       "Claude Code")
    }

    func testUnknownAgentsKeepTheirOwnSpelling() {
        XCTAssertEqual(SessionResolve.agentLabel("mistral"), "Mistral")
        XCTAssertEqual(SessionResolve.agentLabel("unknown"), "Agent")
    }

    // MARK: The panel

    func testSplitPutsWaitingFirstAndDropsEnded() {
        let list = [session("w1", "claude", .working, ago: 5),
                    session("a1", "gemini", .waiting, ago: 300),
                    session("w2", "claude", .compacting, ago: 1),
                    session("x", "claude", .ended)]
        let split = SessionResolve.split(list)
        XCTAssertEqual(split.waiting.map(\.id), ["a1"])
        // Running is newest first: what just changed is what is worth seeing.
        XCTAssertEqual(split.running.map(\.id), ["w2", "w1"])
    }

    func testSplitOrdersWaitingByHowLongItHasWaited() {
        let list = [session("recent", "claude", .waiting, ago: 20),
                    session("stale", "gemini", .waiting, ago: 900)]
        XCTAssertEqual(SessionResolve.split(list).waiting.map(\.id), ["stale", "recent"])
    }
}

@MainActor
final class BridgeDateTests: XCTestCase {

    /// The wire must keep sub-second precision, or two agents that stop in the
    /// same second arrive indistinguishable and the strip names the wrong one.
    func testRoundTripKeepsFractionsOfASecond() throws {
        let early = Date(timeIntervalSince1970: 1_757_450_731.100)
        let late = Date(timeIntervalSince1970: 1_757_450_731.900)

        let data = try JSONEncoder.bridge.encode([early, late])
        let back = try JSONDecoder.bridge.decode([Date].self, from: data)

        XCTAssertLessThan(back[0], back[1])
        XCTAssertEqual(back[0].timeIntervalSince1970, early.timeIntervalSince1970, accuracy: 0.002)
    }

    func testWholeSecondSpellingStillParses() {
        XCTAssertNotNil(BridgeDate.parse("2026-09-09T20:25:31Z"))
        XCTAssertNotNil(BridgeDate.parse("2026-09-09T20:25:31.482Z"))
        XCTAssertNil(BridgeDate.parse("yesterday"))
    }

    /// The whole reason the encoding changed: same second, different instants.
    func testBatonPicksTheOlderOfTwoInTheSameSecond() throws {
        let base = Date(timeIntervalSince1970: 1_757_450_731.100)
        func encoded(_ id: String, _ at: Date) throws -> AgentSession {
            let event = HookEvent(agent: "claude", event: "Stop", status: .waiting,
                                  sessionID: id, workspace: "/p/\(id)", at: at)
            let wire = try JSONDecoder.bridge.decode(
                HookEvent.self, from: JSONEncoder.bridge.encode(event))
            return HookServer.fold(wire, into: []).first!
        }
        // "zeta" stopped first but sorts last by id: only the timestamp can
        // tell them apart, and before this it could not.
        let sessions = [try encoded("alpha", base.addingTimeInterval(0.6)),
                        try encoded("zeta", base)]
        XCTAssertEqual(SessionResolve.baton(sessions)?.title, "zeta")
    }
}
