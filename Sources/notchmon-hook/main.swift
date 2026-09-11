import Foundation
import NotchMonBridge

/// The binary an agent runs when something happens.
///
/// Compiled rather than a script. The other implementations of this ship a
/// Python file and then need a `detectPython()` to find an interpreter on a
/// stranger's machine — a dependency, a PATH search, and a class of failure
/// that reports itself as "the app just doesn't work". This ships in the app
/// bundle beside tokscale and depends on nothing.
///
/// **It exits 0 no matter what.** A non-zero exit from a hook is a signal to
/// the agent, and the signal it sends is "block this". Nothing this binary can
/// fail at is worth interrupting somebody's work for.
///
///     notchmon-hook --agent claude
///
/// with the agent's own JSON on stdin.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// The terminal the agent is running in.
///
/// Read from the PARENT, not from this process: the hook's own stdout is a pipe
/// the agent owns, so `ttyname` here answers about the pipe. The agent is the
/// parent, and its controlling terminal is the one a person would have to click
/// back to.
func parentTTY() -> String? {
    let ppid = getppid()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "tty=", "-p", "\(ppid)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != "??" else { return nil }
    return name.hasPrefix("/dev/") ? name : "/dev/\(name)"
}

let agent = argument("--agent") ?? "unknown"
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]

// Claude Code and its forks use snake_case; Gemini and Grok send camelCase for
// some of the same fields. Both spellings are read rather than guessed at.
func string(_ keys: String...) -> String? {
    for key in keys {
        if let value = payload[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

let event = string("hook_event_name", "hookEventName", "event") ?? "unknown"

let hookEvent = HookEvent(
    agent: agent,
    event: event,
    status: StatusMap.status(forEvent: event, agent: agent),
    sessionID: string("session_id", "sessionId"),
    workspace: string("cwd", "workspace", "workingDirectory"),
    model: string("model"),
    tool: string("tool_name", "toolName"),
    tty: parentTTY(),
    pid: getppid()
)

BridgeClient.send(hookEvent)
exit(0)
