import Foundation
import NotchMonBridge

/// Which source is allowed to say whether an agent is working.
///
/// There are two, and they are not interchangeable. `AgentActivity` watches
/// session files and needs nothing from the agent, which is why it covers every
/// tool tokscale knows about. `HookServer` is the agent's own account of itself,
/// which is why it can tell *waiting for you* from *quiet while thinking* — a
/// distinction file mtimes cannot make, and the one this whole display rests on.
///
/// So hooks do not replace the watcher, they outrank it, **per brand and
/// absolutely**. The two disagree in practice: `Stop` fires at the same moment
/// the agent writes the turn to disk, so for a few seconds the hook says
/// `waiting` while the file says lively. Blending the two produces a chip that
/// pulses "running" beside a lozenge that says "needs you". An agent's own
/// report wins; the file is what we use when there is no report.
enum SessionResolve {

    // MARK: Animation

    /// The liveliness a reported status implies.
    ///
    /// `waiting` deliberately animates nothing. The session is not doing
    /// anything — the lozenge is what speaks for it, and a chip that keeps
    /// blinking would say the opposite.
    static func level(for status: SessionStatus) -> ActivityLevel? {
        switch status {
        case .working: return .lively
        case .compacting: return .settling
        case .waiting, .ended, .unknown: return nil
        }
    }

    /// How alive a brand looks, hooks first.
    ///
    /// A brand can hold several sessions, and the liveliest one speaks for the
    /// chip: one session compacting while another works is, from the strip's
    /// distance, that agent working.
    static func level(for brand: Brand,
                      hook sessions: [AgentSession],
                      watched: [Brand: ActivityLevel]) -> ActivityLevel? {
        let mine = sessions.filter { $0.brand == brand }
        // No report at all is the only case where the file gets a say. A brand
        // that reports and reports `waiting` stays still.
        guard !mine.isEmpty else { return watched[brand] }
        if mine.contains(where: { $0.status == .working }) { return .lively }
        if mine.contains(where: { $0.status == .compacting }) { return .settling }
        return nil
    }

    // MARK: The strip

    /// The one session the strip names, and how many others are waiting behind
    /// it.
    ///
    /// Longest-waiting first, not most recent: the session you just left is the
    /// one you remember, and the one that has been sitting for six minutes is
    /// the one you forgot.
    static func baton(_ sessions: [AgentSession]) -> Baton? {
        let queue = waiting(sessions)
        guard let first = queue.first else { return nil }
        return Baton(session: first, others: queue.count - 1, title: title(for: first))
    }

    // MARK: The panel

    /// The sessions that want you back, longest-waiting first.
    ///
    /// Only these. A running list was here and was removed: shown as bare
    /// project names it read as a list of folders or dependencies, not as
    /// agents at work, and it asked nothing of the person reading it. What is
    /// merely alive is already said by the chips beside the notch and by the
    /// activity they animate; the panel does not need to say it twice in a form
    /// that names the wrong kind of thing.
    static func waiting(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions
            .filter { $0.status == .waiting }
            .sorted { ($0.updated, $0.id) < ($1.updated, $1.id) }
    }

    /// What to call a session on screen.
    ///
    /// The project, not the tool. "Claude Code" does not say which of the four
    /// Claude windows is asking; `notchmon` does, and it is also what the
    /// terminal tab is called.
    static func title(for session: AgentSession) -> String {
        if let workspace = session.workspace?.trimmingCharacters(in: .whitespaces),
           !workspace.isEmpty {
            let name = (workspace as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        return agentLabel(session.agent)
    }

    /// The tool's own name, spelled the way its makers spell it.
    static func agentLabel(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "Claude Code"
        case "gemini": return "Gemini CLI"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "copilot": return "Copilot CLI"
        case "qoder": return "Qoder"
        case "qwen": return "Qwen Code"
        case "factory", "droid": return "Droid"
        case "codebuddy": return "CodeBuddy"
        case "opencode": return "OpenCode"
        case "unknown", "": return "Agent"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
}

/// What the strip says when something needs you.
struct Baton: Equatable {
    var session: AgentSession
    /// Others also waiting. Named separately rather than folded into the title,
    /// because the whole point of the lozenge is that it names one thing.
    var others: Int
    var title: String
}
