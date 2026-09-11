import XCTest
@testable import NotchMon

/// Folding a workspace scan into one row per project.
///
/// The bug this pins: a project worked on by two agents counted both in its
/// totals and named only whichever one tokscale happened to emit first. The
/// row wore one agent's mark while reporting the other's tokens inside its own,
/// so the second agent read as never having run there.
final class ProjectFoldTests: XCTestCase {
    private func entry(
        _ client: String, _ workspace: String, model: String,
        tokens: Int, cost: Double, messages: Int = 1
    ) -> ProjectEntry {
        ProjectEntry(
            client: client, workspaceKey: "/Users/x/\(workspace)", workspaceLabel: workspace,
            model: model, input: tokens, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: messages, cost: cost)
    }

    /// The real shape of the data that exposed it: Claude does most of the work
    /// in `watchr`, Codex does a little, and the Codex row arrives last.
    func testEveryAgentInAProjectIsKept() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 11_435_638, cost: 11.96),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 221_656, cost: 0.31)
        ])
        guard let row = ProjectUsage.fold(report).first else { return XCTFail("no row") }

        XCTAssertEqual(row.agents.map(\.client), ["claude", "codex"])
        XCTAssertEqual(row.tokens, 11_657_294)
        XCTAssertEqual(row.cost, 12.27, accuracy: 0.001)
    }

    /// Order is by weight, not by arrival — the row's single mark and the first
    /// rail segment both come off the front of this list.
    func testAgentsAreOrderedByTokensWhicheverArrivesFirst() {
        let report = ProjectReport(entries: [
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 200, cost: 0.30),
            entry("claude", "watchr", model: "claude-opus-5", tokens: 9_000, cost: 0.10)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents.map(\.client), ["claude", "codex"])
        XCTAssertEqual(row.brand, Brand.claude)
    }

    /// By tokens rather than cost, because an agent can do a great deal of work
    /// on a plan that bills it at nothing and it still worked here.
    func testAFreeAgentDoingMostOfTheWorkLeads() {
        let report = ProjectReport(entries: [
            entry("copilot", "watchr", model: "gpt-5", tokens: 50_000, cost: 0),
            entry("claude", "watchr", model: "claude-opus-5", tokens: 1_000, cost: 9.99)
        ])
        XCTAssertEqual(ProjectUsage.fold(report)[0].agents.first?.client, "copilot")
    }

    /// One agent's several models fold into that agent, not into several rows.
    func testModelsFoldIntoTheirAgent() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 100, cost: 2),
            entry("claude", "watchr", model: "claude-fable-5-1", tokens: 300, cost: 1)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents.count, 1)
        XCTAssertEqual(row.agents[0].tokens, 400)
        // The label names the model that SPENT most, which is not the one that
        // produced the most tokens.
        XCTAssertEqual(row.model, "claude-opus-5")
    }

    func testSharesSumToOneAndFollowTheAgents() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 750, cost: 1),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 250, cost: 1)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.shares, [0.75, 0.25])
    }

    /// Nothing here knows which agents exist. A tool tokscale learns about later
    /// has to appear without a code change.
    func testAnUnknownAgentStillAppears() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 100, cost: 1),
            entry("brand-new-tool", "watchr", model: "who-knows", tokens: 900, cost: 1)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents.first?.client, "brand-new-tool")
        XCTAssertEqual(row.agents.first?.brand, Brand.generic)
        XCTAssertEqual(row.tokens, 1_000)
    }

    /// Separate projects stay separate however the entries interleave.
    func testProjectsDoNotBleedIntoEachOther() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 100, cost: 1),
            entry("codex", "mon-dex", model: "gpt-6-astra", tokens: 200, cost: 5),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 300, cost: 2)
        ])
        let rows = ProjectUsage.fold(report)
        XCTAssertEqual(rows.map(\.name), ["mon-dex", "watchr"])
        XCTAssertEqual(rows.first(where: { $0.name == "watchr" })?.agents.count, 2)
        XCTAssertEqual(rows.first(where: { $0.name == "mon-dex" })?.agents.count, 1)
    }

    // MARK: What the detail pane reads

    /// Each agent carries its own models, sorted by weight, so the pane can
    /// name them under that agent's bar rather than under the project.
    func testEachAgentCarriesItsOwnModels() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-fable-5-1", tokens: 300, cost: 1),
            entry("claude", "watchr", model: "claude-opus-5", tokens: 900, cost: 8),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 400, cost: 2)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents.map(\.client), ["claude", "codex"])
        XCTAssertEqual(row.agents[0].models.map(\.model), ["claude-opus-5", "claude-fable-5-1"])
        XCTAssertEqual(row.agents[1].models.map(\.model), ["gpt-6-astra"])
        XCTAssertEqual(row.modelCount, 3)
    }

    /// The pane prints a message count per agent, not just per project.
    func testMessagesSplitByAgent() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 100, cost: 1, messages: 138),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 90, cost: 1, messages: 7)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents.map(\.messages), [138, 7])
        XCTAssertEqual(row.messages, 145)
    }

    /// The vendor prefix comes off: the agent's own mark is on the line above,
    /// so repeating it in the model name spends width on a settled question.
    func testModelNamesDropTheVendorPrefix() {
        let report = ProjectReport(entries: [
            entry("claude", "watchr", model: "claude-opus-5", tokens: 100, cost: 1),
            entry("codex", "watchr", model: "gpt-6-astra", tokens: 90, cost: 1)
        ])
        let row = ProjectUsage.fold(report)[0]
        XCTAssertEqual(row.agents[0].models[0].short, "opus-5")
        XCTAssertEqual(row.agents[1].models[0].short, "gpt-6-astra")
    }

    /// The split the fold used to throw away. Cache reads are around 98% of a
    /// real project's tokens, and that is the fact a bare token count hides.
    func testTokenMixIsKeptAndCachedShareFollowsIt() {
        let mixed = ProjectEntry(
            client: "claude", workspaceKey: "/Users/x/watchr", workspaceLabel: "watchr",
            model: "claude-opus-5", input: 274, output: 148_035, cacheRead: 20_425_341,
            cacheWrite: 1_066_804, reasoning: 24, messageCount: 137, cost: 20.58)
        let row = ProjectUsage.fold(ProjectReport(entries: [mixed, mixed]))[0]

        XCTAssertEqual(row.mix.input, 548)
        XCTAssertEqual(row.mix.cacheRead, 40_850_682)
        XCTAssertEqual(row.mix.reasoning, 48)
        // The mix has to account for every token the row reports, or the bar
        // under it would be drawn against a different total than the figure
        // beside it.
        XCTAssertEqual(row.mix.total, row.tokens)
        XCTAssertEqual(row.mix.cachedShare, 0.9438, accuracy: 0.0001)
    }

    /// An entry with no model named still worked here; dropping it would leave
    /// that agent's bar with nothing underneath it.
    func testAnAgentWithNoModelNamedStillGetsALine() {
        let nameless = ProjectEntry(
            client: "codex", workspaceKey: "/Users/x/watchr", workspaceLabel: "watchr",
            model: nil, input: 500, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 2, cost: 0.4)
        let row = ProjectUsage.fold(ProjectReport(entries: [nameless]))[0]
        XCTAssertEqual(row.agents[0].models.map(\.model), ["unknown"])
    }

    /// A session outside any repository still spent money; hiding it would make
    /// this page's total disagree with the header's.
    func testWorkOutsideAnyProjectIsStillCounted() {
        let loose = ProjectEntry(
            client: "claude", workspaceKey: nil, workspaceLabel: nil,
            model: "claude-opus-5", input: 42, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 1, cost: 0.5)
        let rows = ProjectUsage.fold(ProjectReport(entries: [loose]))
        XCTAssertEqual(rows.map(\.name), ["elsewhere"])
        XCTAssertEqual(rows[0].tokens, 42)
    }
}

/// The spellings below are the real ones, read off this machine with
/// `tokscale --group-by workspace,model --today` — the form the app falls back
/// to whenever worktree merging times out at launch.
@MainActor
final class ProjectSpellingTests: XCTestCase {

    private func entry(_ client: String, key: String, label: String,
                       tokens: Int, cost: Double) -> ProjectEntry {
        ProjectEntry(client: client, workspaceKey: key, workspaceLabel: label,
                     model: "m", input: tokens, output: 0, cacheRead: 0, cacheWrite: 0,
                     reasoning: 0, messageCount: 1, cost: cost)
    }

    func testTwoAgentsSpellingOneDirectoryDifferentlyAreOneProject() {
        let folded = ProjectUsage.fold(ProjectReport(entries: [
            entry("claude", key: "-Users-huypham-Desktop-projects-mon-dex",
                  label: "mon-dex (-Users-huypham-Desktop-projects-mon-dex)",
                  tokens: 100, cost: 83.54),
            entry("codex", key: "/Users/huypham/Desktop/projects/mon-dex",
                  label: "mon-dex (/Users/huypham/Desktop/projects/mon-dex)",
                  tokens: 30, cost: 2.62)
        ]))

        XCTAssertEqual(folded.count, 1, "one directory is one project")
        XCTAssertEqual(folded.first?.name, "mon-dex",
                       "and the path suffix goes, because it was only ever there to tell them apart")
        XCTAssertEqual(folded.first?.cost ?? 0, 86.16, accuracy: 0.001)
        XCTAssertEqual(folded.first?.agents.map(\.client), ["claude", "codex"])
    }

    func testADashInTheDirectoryNameSurvives() {
        // The naive repair — dashes back to slashes — turns `mon-dex` into
        // `mon/dex` and would file it under a directory that cannot exist.
        XCTAssertEqual(ProjectUsage.canonical("-Users-x-mon-dex"),
                       ProjectUsage.canonical("/Users/x/mon-dex"))
        XCTAssertNotEqual(ProjectUsage.canonical("/Users/x/mon-dex"),
                          ProjectUsage.canonical("/Users/x/other-dex"))
    }

    func testTwoRealProjectsSharingABasenameStayApart() {
        let folded = ProjectUsage.fold(ProjectReport(entries: [
            entry("claude", key: "/Users/x/work/atlas", label: "atlas (/Users/x/work/atlas)",
                  tokens: 10, cost: 1),
            entry("claude", key: "/Users/x/play/atlas", label: "atlas (/Users/x/play/atlas)",
                  tokens: 10, cost: 2)
        ]))
        XCTAssertEqual(folded.count, 2, "different directories, whatever they are called")
        XCTAssertEqual(Set(folded.map(\.name)).count, 2,
                       "and they keep the suffix that tells them apart")
    }

    func testAProjectCalledSomethingInBracketsKeepsItsName() {
        let folded = ProjectUsage.fold(ProjectReport(entries: [
            entry("claude", key: "/Users/x/atlas", label: "atlas (v2)", tokens: 10, cost: 1),
            entry("codex", key: "/Users/x/atlas", label: "atlas (v2)", tokens: 10, cost: 1)
        ]))
        XCTAssertEqual(folded.first?.name, "atlas (v2)")
    }

    func testWorkOutsideAnyProjectStillFoldsTogether() {
        let folded = ProjectUsage.fold(ProjectReport(entries: [
            ProjectEntry(client: "claude", workspaceKey: nil, workspaceLabel: nil, model: "m",
                         input: 5, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0,
                         messageCount: 1, cost: 1),
            ProjectEntry(client: "codex", workspaceKey: nil, workspaceLabel: nil, model: "m",
                         input: 5, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0,
                         messageCount: 1, cost: 1)
        ]))
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded.first?.name, "elsewhere")
    }
}
