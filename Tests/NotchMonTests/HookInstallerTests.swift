import XCTest
@testable import NotchMon

final class HookInstallerTests: XCTestCase {

    private let hook = "/Applications/NotchMon.app/Contents/Resources/notchmon-hook --agent claude"

    private func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        groups(root, event).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// A file that already holds three other hook systems, which is what the
    /// user's own machine looks like.
    private var crowded: [String: Any] {
        ["hooks": [
            "PreToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": "python3 ~/.claude/hooks/claude-island-state.py"]]],
                ["matcher": "ExitPlanMode", "hooks": [["type": "command", "command": "~/.coldtea/shell/hooks/claude-artifact.sh"]]],
            ],
            "PermissionRequest": [
                ["matcher": "*", "hooks": [["type": "command", "command": "python3 ~/.claude/hooks/claude-island-state.py", "timeout": 86400]]],
            ],
        ],
         "model": "opus",
         "statusLine": ["type": "command", "command": "mine"]]
    }

    // MARK: Idempotency

    func testInstallingTwiceRegistersOnce() {
        let once = HookInstaller.installed([:], hook: hook, dialect: .claude)
        let twice = HookInstaller.installed(once, hook: hook, dialect: .claude)
        XCTAssertEqual(commands(twice, "UserPromptSubmit"), [hook])
        XCTAssertEqual(commands(twice, "Stop"), [hook])
    }

    /// The case string equality would miss: the app moved, so the command is
    /// not the same string, but the entry is still ours.
    func testAnEntryFromAnOlderLocationIsReplacedNotDuplicated() {
        let old = "/Users/x/Downloads/NotchMon.app/Contents/Resources/notchmon-hook --agent claude"
        let existing = HookInstaller.installed([:], hook: old, dialect: .claude)
        let now = HookInstaller.installed(existing, hook: hook, dialect: .claude)
        XCTAssertEqual(commands(now, "PreToolUse"), [hook])
    }

    /// An event we used to register and no longer do must not be left firing a
    /// binary that may not exist.
    func testEntriesForEventsWeNoLongerRegisterAreRemoved() {
        var stale: [String: Any] = ["hooks": ["PermissionRequest": [
            ["matcher": "*", "hooks": [["type": "command", "command": hook]]],
        ]]]
        stale = HookInstaller.installed(stale, hook: hook, dialect: .claude)
        XCTAssertTrue(commands(stale, "PermissionRequest").isEmpty)
        XCTAssertNil((stale["hooks"] as? [String: Any])?["PermissionRequest"])
    }

    // MARK: Leaving other people's things alone

    func testOtherHookSystemsSurviveIntact() {
        let after = HookInstaller.installed(crowded, hook: hook, dialect: .claude)
        XCTAssertTrue(commands(after, "PreToolUse").contains("python3 ~/.claude/hooks/claude-island-state.py"))
        XCTAssertTrue(commands(after, "PreToolUse").contains("~/.coldtea/shell/hooks/claude-artifact.sh"))
        // Including for an event we deliberately do not register.
        XCTAssertEqual(commands(after, "PermissionRequest").count, 1)
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertNotNil(after["statusLine"])
    }

    func testWeNeverRegisterPermissionRequest() {
        let after = HookInstaller.installed([:], hook: hook, dialect: .claude)
        XCTAssertFalse(HookInstaller.Dialect.claude.events.contains("PermissionRequest"))
        XCTAssertTrue(commands(after, "PermissionRequest").isEmpty)
    }

    // MARK: Removal

    func testUninstallLeavesTheFileAsItWasFound() {
        let after = HookInstaller.installed(crowded, hook: hook, dialect: .claude)
        let back = HookInstaller.uninstalled(after)
        XCTAssertEqual(commands(back, "PreToolUse").count, 2)
        XCTAssertTrue(commands(back, "UserPromptSubmit").isEmpty)
        XCTAssertNil((back["hooks"] as? [String: Any])?["UserPromptSubmit"])
        XCTAssertEqual(back["model"] as? String, "opus")
    }

    func testUninstallDropsAnEmptyHooksBlockEntirely() {
        let after = HookInstaller.installed(["model": "opus"], hook: hook, dialect: .claude)
        let back = HookInstaller.uninstalled(after)
        XCTAssertNil(back["hooks"])
        XCTAssertEqual(back["model"] as? String, "opus")
    }

    // MARK: Dialects

    func testPreCompactRegistersUnderBothMatchers() {
        let after = HookInstaller.installed([:], hook: hook, dialect: .claude)
        let matchers = groups(after, "PreCompact").compactMap { $0["matcher"] as? String }
        XCTAssertEqual(matchers.sorted(), ["auto", "manual"])
    }

    func testGeminiUsesItsOwnEventNamesAndNoMatcher() {
        let after = HookInstaller.installed([:], hook: hook, dialect: .gemini)
        XCTAssertEqual(commands(after, "BeforeAgent"), [hook])
        XCTAssertTrue(commands(after, "UserPromptSubmit").isEmpty)
        XCTAssertNil(groups(after, "BeforeAgent").first?["matcher"])
    }

    // MARK: Detection and the command line

    func testOnlyAgentsWithAConfigDirectoryAreOffered() {
        let present = ["/h/.claude", "/h/.gemini"]
        let found = HookInstaller.detected(home: "/h") { present.contains($0) }
        XCTAssertEqual(found.map(\.id), ["claude", "gemini"])
    }

    func testAPathWithASpaceIsQuoted() {
        let target = HookInstaller.known(home: "/h").first { $0.id == "claude" }!
        let spaced = HookInstaller.command(for: target, binary: "/My Apps/NotchMon.app/x/notchmon-hook")
        XCTAssertEqual(spaced, "\"/My Apps/NotchMon.app/x/notchmon-hook\" --agent claude")
        let plain = HookInstaller.command(for: target, binary: "/Applications/NotchMon.app/x/notchmon-hook")
        XCTAssertEqual(plain, "/Applications/NotchMon.app/x/notchmon-hook --agent claude")
    }

    // MARK: On disk

    func testWriteIsWholeAndBacksUpTheOriginalOnce() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json").path
        let original = try JSONSerialization.data(withJSONObject: crowded)
        try original.write(to: URL(fileURLWithPath: path))

        try HookInstaller.apply(to: path, hook: hook, dialect: .claude)
        try HookInstaller.apply(to: path, hook: hook, dialect: .claude)

        let reread = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(commands(reread, "UserPromptSubmit"), [hook])
        XCTAssertEqual(reread["model"] as? String, "opus")

        // The backup is from before this app ever touched the file, not from
        // before the most recent write.
        let backup = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path + ".notchmon-backup"))) as! [String: Any]
        XCTAssertTrue(commands(backup, "UserPromptSubmit").isEmpty)
    }

    func testARewriteOfAnUnchangedFileProducesIdenticalBytes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))

        try HookInstaller.apply(to: path, hook: hook, dialect: .claude)
        let first = try Data(contentsOf: URL(fileURLWithPath: path))
        try HookInstaller.apply(to: path, hook: hook, dialect: .claude)
        let second = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(first, second)
    }

    func testAFileThatIsNotJSONIsRefusedRatherThanOverwritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json").path
        try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try HookInstaller.apply(to: path, hook: hook, dialect: .claude))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{ this is not json")
    }
}
