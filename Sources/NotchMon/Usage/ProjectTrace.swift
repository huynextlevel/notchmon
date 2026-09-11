import Foundation

/// Which project a session file belongs to.
///
/// This is what lets the app say where the hours went, and it costs no new
/// permission and no new watcher: the paths are the ones `AgentActivity` is
/// already told about, and every client puts the answer somewhere in or beside
/// them.
///
/// Two shapes, because the two clients on this machine disagree:
///
/// - Claude keeps one directory per workspace and encodes the path into its
///   name — `~/.claude/projects/-Users-huypham-Desktop-projects-mon-dex/<id>.jsonl`.
///   The directory *is* the answer.
/// - Codex files by date — `~/.codex/sessions/2026/09/11/rollout-….jsonl` — and
///   carries the working directory inside the file instead.
///
/// So the path is tried first and the file is opened only when it has to be.
/// The answer is keyed the same way `ProjectUsage` keys its buckets, which is
/// the whole point: the hours and the money have to land in the same bucket or
/// they cannot be divided into each other.
enum ProjectTrace {
    /// Keyed by path. A session file is written hundreds of times and its
    /// project never changes, so this is read once per file rather than once
    /// per write.
    private static var known: [String: String?] = [:]
    /// Bytes read looking for a working directory. The field is in the first
    /// record every client writes; anything past this is not a session header.
    private static let sniff = 64 * 1024

    static func project(forSession path: String) -> String? {
        if let seen = known[path] { return seen }
        let found = fromPath(path) ?? fromFile(path)
        known[path] = found
        return found
    }

    /// Claude's encoded directory, and anything else that keeps sessions in a
    /// folder named after the workspace.
    private static func fromPath(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let projects = parts.lastIndex(of: "projects"), projects + 1 < parts.count else {
            return nil
        }
        let folder = parts[projects + 1]
        // The encoded form always starts at the filesystem root, which is the
        // only thing telling it apart from a folder somebody named "web".
        guard folder.hasPrefix("-") else { return nil }
        return ProjectUsage.canonical(folder)
    }

    /// The working directory, from the file's own head.
    private static func fromFile(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sniff),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        for line in text.split(separator: "\n").prefix(8) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            if let cwd = directory(in: object) { return ProjectUsage.canonical(cwd) }
        }
        return nil
    }

    /// Depth-first for the first plausible directory. The key is spelled `cwd`
    /// by both clients seen here, and nested one level down by one of them, so
    /// this looks rather than assumes.
    private static func directory(in object: Any, depth: Int = 0) -> String? {
        guard depth < 4, let map = object as? [String: Any] else { return nil }
        for key in ["cwd", "workingDirectory", "workspace", "projectPath"] {
            if let value = map[key] as? String, value.hasPrefix("/") { return value }
        }
        for value in map.values {
            if let found = directory(in: value, depth: depth + 1) { return found }
        }
        return nil
    }

    /// For tests, and for a roster that changed under the app.
    static func forget() { known.removeAll() }
}
