import Foundation

/// Writing the hook into an agent's own configuration.
///
/// This edits files this app does not own, that other tools also write to, and
/// that an agent reads on every turn. The user's own `~/.claude/settings.json`
/// already carries three unrelated hook systems. So the rules here are not
/// stylistic:
///
/// * **Idempotent by identity, not by equality.** Our entries are found by the
///   command naming `notchmon-hook`, then removed and rewritten. Matching on
///   the exact string would append a second copy the first time the app moves
///   from `~/Downloads` to `/Applications`.
/// * **Nothing else is touched.** Other tools' entries are carried across
///   untouched, in order, including for events we do not register.
/// * **Written whole or not at all.** A partial write here breaks every hook
///   system in the file, not just ours.
enum HookInstaller {

    /// Which vocabulary an agent speaks. The *shape* is the same for both —
    /// verified against the Gemini config on a real machine, which nests
    /// `hooks: [{type, command}]` exactly as Claude Code does. Only the event
    /// names differ, and Claude's take a matcher.
    enum Dialect {
        case claude
        case gemini

        /// The events worth registering.
        ///
        /// `PermissionRequest` is deliberately absent. It is the one hook that
        /// *answers* — the agent blocks on the reply — and on this machine it
        /// already has three handlers competing to decide the same question.
        /// Joining that queue is a much larger promise than reporting status,
        /// and it is not what this release makes.
        var events: [String] {
            switch self {
            case .claude:
                return ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
                        "SubagentStop", "Notification", "SessionStart", "SessionEnd",
                        "PreCompact"]
            case .gemini:
                return ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent",
                        "PreCompress", "SessionStart", "SessionEnd"]
            }
        }

        /// Matchers to register an event under.
        ///
        /// `PreCompact` gets `auto` and `manual` rather than `*`, copying the
        /// installer already working on this machine: a wildcard is not known
        /// to match there, and guessing wrong means the hook silently never
        /// fires.
        func matchers(for event: String) -> [String?] {
            switch self {
            case .gemini: return [nil]
            case .claude: return event == "PreCompact" ? ["auto", "manual"] : ["*"]
            }
        }
    }

    /// One agent's configuration file.
    struct Target: Identifiable, Equatable {
        var id: String
        var name: String
        var path: String
        var dialect: Dialect

        static func == (a: Target, b: Target) -> Bool { a.id == b.id && a.path == b.path }
    }

    /// Every agent this release knows how to write to, whether or not it is
    /// installed.
    ///
    /// Keyed off the config directory rather than a binary on `PATH`: these
    /// tools arrive by npm, brew, curl and app bundle, and `PATH` inside a
    /// GUI app is not the `PATH` a person has in their terminal.
    static func known(home: String) -> [Target] {
        [
            Target(id: "claude", name: "Claude Code", path: "\(home)/.claude/settings.json", dialect: .claude),
            Target(id: "qoder", name: "Qoder", path: "\(home)/.qoder/settings.json", dialect: .claude),
            Target(id: "qwen", name: "Qwen Code", path: "\(home)/.qwen/settings.json", dialect: .claude),
            Target(id: "factory", name: "Droid", path: "\(home)/.factory/settings.json", dialect: .claude),
            Target(id: "codebuddy", name: "CodeBuddy", path: "\(home)/.codebuddy/settings.json", dialect: .claude),
            Target(id: "gemini", name: "Gemini CLI", path: "\(home)/.gemini/settings.json", dialect: .gemini),
        ]
    }

    /// The ones actually on this machine.
    ///
    /// The *directory* is the evidence, not the file: an agent that has never
    /// been configured has no `settings.json`, and refusing to set it up for
    /// that reason would be backwards.
    static func detected(home: String, exists: (String) -> Bool) -> [Target] {
        known(home: home).filter { exists((($0.path as NSString).deletingLastPathComponent)) }
    }

    // MARK: Editing

    /// Whether a command belongs to us.
    ///
    /// The name of the binary, not the whole path, so moving the app does not
    /// orphan the entry it wrote last time.
    static func isOurs(_ command: String) -> Bool { command.contains("notchmon-hook") }

    /// A configuration with our hook registered, and everyone else's left alone.
    ///
    /// Pure, and takes the parsed object rather than a path, so the whole of the
    /// decision-making can be tested without writing to anybody's home
    /// directory.
    static func installed(_ root: [String: Any], hook: String, dialect: Dialect) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Every event first, including ones we no longer register: an entry
        // left behind by an older version would go on firing a binary that may
        // not exist.
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = strip(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }

        for event in dialect.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            for matcher in dialect.matchers(for: event) {
                var group: [String: Any] = ["hooks": [["type": "command", "command": hook]]]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[event] = groups
        }

        root["hooks"] = hooks
        return root
    }

    /// The same file with our hook removed and nothing else changed.
    static func uninstalled(_ root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = strip(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        // An empty `hooks` is not the same as no `hooks`, but leaving `{}`
        // behind in a file we were asked to withdraw from is untidy.
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    /// Drops our commands from one event's groups, and drops a group that held
    /// nothing else.
    private static func strip(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            let kept = entries.filter { !isOurs($0["command"] as? String ?? "") }
            if kept.isEmpty { return nil }
            var group = group
            group["hooks"] = kept
            return group
        }
    }

    // MARK: Writing

    enum InstallError: Error {
        case unreadable(String)
        case notAnObject(String)
    }

    /// Reads, edits and replaces one configuration file.
    ///
    /// The replacement is written beside the original and moved onto it, so a
    /// reader either sees the old file or the new one. An agent reads this file
    /// on every turn; a half-written one would break three other tools as well
    /// as this one.
    @discardableResult
    static func apply(to path: String, hook: String, dialect: Dialect,
                      remove: Bool = false) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        var root: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                    throw InstallError.unreadable(path)
                }
                guard let object = parsed as? [String: Any] else {
                    throw InstallError.notAnObject(path)
                }
                root = object
                // One backup, kept from the first time we ever touched the
                // file: the copy worth having is the one from before any of
                // this app's edits, not from before the most recent one.
                let backup = path + ".notchmon-backup"
                if !FileManager.default.fileExists(atPath: backup) {
                    try? data.write(to: URL(fileURLWithPath: backup))
                }
            }
        }

        let edited = remove
            ? uninstalled(root)
            : installed(root, hook: hook, dialect: dialect)

        // Sorted so that a file this app rewrites twice produces the same bytes
        // twice, which is what makes "did anything change?" answerable.
        let out = try JSONSerialization.data(
            withJSONObject: edited, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".notchmon-\(UUID().uuidString).tmp")
        try out.write(to: staging)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        return edited
    }

    /// Where the hook binary lives inside the running app.
    static var hookCommand: String {
        Bundle.main.url(forResource: "notchmon-hook", withExtension: nil)?.path
            ?? "/Applications/NotchMon.app/Contents/Resources/notchmon-hook"
    }

    /// The command as it is written into a config, agent name included.
    static func command(for target: Target, binary: String = hookCommand) -> String {
        "\(quoted(binary)) --agent \(target.id)"
    }

    /// A path with a space in it — `/Applications/My Apps/NotchMon.app` — is a
    /// command that runs the wrong thing or nothing.
    private static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
