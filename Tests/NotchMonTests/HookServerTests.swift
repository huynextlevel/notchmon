import XCTest
@testable import NotchMon
@testable import NotchMonBridge

/// Folding hook events into a list of live sessions.
@MainActor
final class HookServerTests: XCTestCase {
    private func event(_ e: String, agent: String = "claude", session: String? = "s1",
                       workspace: String? = nil, model: String? = nil, tool: String? = nil,
                       tty: String? = nil, at: Date = Date()) -> HookEvent {
        HookEvent(agent: agent, event: e,
                  status: StatusMap.status(forEvent: e, agent: agent),
                  sessionID: session, workspace: workspace, model: model,
                  tool: tool, tty: tty, at: at)
    }

    func testAPromptStartsAWorkingSession() {
        let out = HookServer.fold(event("UserPromptSubmit", workspace: "/x/watchr"), into: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, .working)
        XCTAssertEqual(out[0].workspace, "/x/watchr")
    }

    /// The bug this whole channel exists to fix. Thinking writes nothing to
    /// disk for 26 seconds, so file-mtime activity called it idle. An event
    /// says otherwise and keeps saying it until Stop arrives.
    func testAWorkingSessionStaysWorkingUntilStop() {
        var out = HookServer.fold(event("UserPromptSubmit"), into: [])
        out = HookServer.fold(event("PreToolUse", tool: "Bash"), into: out)
        XCTAssertEqual(out[0].status, .working)
        XCTAssertEqual(out[0].tool, "Bash")

        out = HookServer.fold(event("Stop"), into: out)
        XCTAssertEqual(out[0].status, .waiting)
    }

    /// A Stop carries no model. Blanking what the last event knew would make
    /// the panel flicker between knowing and not knowing.
    func testFieldsAbsentFromAnEventKeepTheirLastValue() {
        var out = HookServer.fold(event("UserPromptSubmit", workspace: "/x/w", model: "opus-5"), into: [])
        out = HookServer.fold(event("Stop"), into: out)
        XCTAssertEqual(out[0].model, "opus-5")
        XCTAssertEqual(out[0].workspace, "/x/w")
    }

    func testSessionEndRemovesIt() {
        var out = HookServer.fold(event("UserPromptSubmit"), into: [])
        out = HookServer.fold(event("SessionEnd"), into: out)
        XCTAssertTrue(out.isEmpty)
    }

    func testTwoAgentsAreTwoSessions() {
        var out = HookServer.fold(event("UserPromptSubmit", agent: "claude", session: "a"), into: [])
        out = HookServer.fold(event("BeforeAgent", agent: "gemini", session: "b"), into: out)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.agent)), ["claude", "gemini"])
        XCTAssertEqual(out.first { $0.agent == "gemini" }?.status, .working)
    }

    /// An event with no session id still says an agent is alive; the terminal
    /// is the next most stable handle. Dropping it would lose whole agents.
    func testAnEventWithNoSessionIdIsKeyedOnTheTerminal() {
        let out = HookServer.fold(event("UserPromptSubmit", session: nil, tty: "/dev/ttys004"), into: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "/dev/ttys004")
    }

    func testAnEventWithNeitherIsIgnored() {
        XCTAssertTrue(HookServer.fold(event("Stop", session: nil, tty: nil), into: []).isEmpty)
    }

    func testSilentSessionsArePruned() {
        let old = AgentSession(id: "a", agent: "claude", status: .waiting, updated: Date(timeIntervalSinceNow: -3600))
        let fresh = AgentSession(id: "b", agent: "claude", status: .working, updated: Date())
        XCTAssertEqual(HookServer.pruned([old, fresh]).map(\.id), ["b"])
    }
}

/// The one table a new agent changes.
final class StatusMapTests: XCTestCase {
    func testClaudeCodeVocabulary() {
        XCTAssertEqual(StatusMap.status(forEvent: "UserPromptSubmit", agent: "claude"), .working)
        XCTAssertEqual(StatusMap.status(forEvent: "Stop", agent: "claude"), .waiting)
        XCTAssertEqual(StatusMap.status(forEvent: "SessionEnd", agent: "claude"), .ended)
        XCTAssertEqual(StatusMap.status(forEvent: "PreCompact", agent: "claude"), .compacting)
    }

    /// Qoder, Qwen Code, Factory and CodeBuddy are Claude Code forks and send
    /// its event names verbatim — which is why one table serves five agents.
    func testClaudeForksReuseTheSameNames() {
        for fork in ["qoder", "qwen", "factory", "codebuddy"] {
            XCTAssertEqual(StatusMap.status(forEvent: "UserPromptSubmit", agent: fork), .working)
            XCTAssertEqual(StatusMap.status(forEvent: "Stop", agent: fork), .waiting)
        }
    }

    /// Gemini names the same moments differently, and that is the whole reason
    /// normalising happens at the edge rather than in the app.
    func testGeminiVocabulary() {
        XCTAssertEqual(StatusMap.status(forEvent: "BeforeTool", agent: "gemini"), .working)
        XCTAssertEqual(StatusMap.status(forEvent: "AfterAgent", agent: "gemini"), .waiting)
        XCTAssertEqual(StatusMap.status(forEvent: "PreCompress", agent: "gemini"), .compacting)
    }

    func testAnUnknownEventIsNotInvented() {
        XCTAssertEqual(StatusMap.status(forEvent: "SomethingNew", agent: "claude"), .unknown)
    }
}
