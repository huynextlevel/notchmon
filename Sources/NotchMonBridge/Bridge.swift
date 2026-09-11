import Foundation

/// The wire between an agent's hook and the app.
///
/// Shared by both sides on purpose. The hook is a separate binary running in a
/// different process, invoked by a tool this app does not control, and the one
/// failure nobody would notice is the two ends drifting into disagreement about
/// the shape of a message.
public enum Bridge {
    /// Per-user, not a fixed path.
    ///
    /// A constant `/tmp/notchmon.sock` is what the other implementations of this
    /// idea use and it is wrong twice over: on a machine with two accounts
    /// logged in the second one cannot bind, and either account can read the
    /// other's traffic. `getuid()` costs nothing and settles both.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["NOTCHMON_SOCKET_PATH"],
           !override.isEmpty {
            return override
        }
        return "/tmp/notchmon-\(getuid()).sock"
    }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, and a path that overflows
    /// it fails at bind with an error nobody reads. Checked rather than assumed.
    public static let maxPathLength = 103
}

/// What the app is told when something happens inside an agent.
///
/// One shape for every agent. The event names differ — Claude Code says
/// `UserPromptSubmit` where Gemini says `BeforeAgent` — so the normalising is
/// done at the edge, in the hook, and the app never learns a vocabulary per
/// vendor.
public struct HookEvent: Codable, Equatable, Sendable {
    public var agent: String
    /// The agent's own name for what happened, kept beside the normalised
    /// status: when a status turns out wrong, this is the only thing that says
    /// what it was derived from.
    public var event: String
    public var status: SessionStatus
    public var sessionID: String?
    public var workspace: String?
    public var model: String?
    public var tool: String?
    /// The terminal the agent is running in. The whole of jump-back rests on
    /// this one string.
    public var tty: String?
    public var pid: Int32?
    public var at: Date

    public init(agent: String, event: String, status: SessionStatus,
                sessionID: String? = nil, workspace: String? = nil,
                model: String? = nil, tool: String? = nil,
                tty: String? = nil, pid: Int32? = nil, at: Date = Date()) {
        self.agent = agent
        self.event = event
        self.status = status
        self.sessionID = sessionID
        self.workspace = workspace
        self.model = model
        self.tool = tool
        self.tty = tty
        self.pid = pid
        self.at = at
    }
}

/// What the strip needs to know, and nothing more.
///
/// Four states rather than one bit, because "running" and "waiting for you" ask
/// different things of the person looking: one is a reason to leave it alone,
/// the other is a reason to go back.
public enum SessionStatus: String, Codable, Sendable {
    case working, waiting, compacting, ended, unknown
}

/// Which status an agent's own event name means.
///
/// A pure function so the mapping can be tested against real event names
/// without an agent, a socket or a running app — and the mapping is the only
/// part of this that a new agent changes.
public enum StatusMap {
    public static func status(forEvent event: String, agent: String) -> SessionStatus {
        switch event {
        // Claude Code, and every fork that copied its schema: Qoder, Qwen Code,
        // Factory, CodeBuddy.
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
        case "Stop", "SubagentStop", "Notification": return .waiting
        case "SessionStart": return .waiting
        case "SessionEnd": return .ended
        case "PreCompact": return .compacting

        // Gemini CLI names the same moments differently. `BeforeTool` is its
        // `PreToolUse`; `PreCompress` its `PreCompact`.
        case "BeforeAgent", "BeforeTool", "AfterTool", "BeforeModel", "AfterModel":
            return .working
        case "AfterAgent": return .waiting
        case "PreCompress": return .compacting

        default: return .unknown
        }
    }
}
