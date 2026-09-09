import Combine
import Foundation
import NotchMonBridge

/// A session nobody has heard from in this long is gone: agents are killed,
/// terminals are closed, and `SessionEnd` does not always arrive.
///
/// Outside the class because a default argument is evaluated by the caller, and
/// a caller off the main actor cannot read a main-actor constant.
let hookSessionSilence: TimeInterval = 30 * 60

/// One live session, as the strip and the panel need it.
struct AgentSession: Identifiable, Equatable {
    var id: String
    var agent: String
    var status: SessionStatus
    var workspace: String?
    var model: String?
    var tool: String?
    var tty: String?
    var pid: Int32?
    var updated: Date

    var brand: Brand { Brand.match(agent) }
}

/// Listens for what agents report about themselves.
///
/// **Why this replaces guessing.** Activity used to be inferred from the mtime
/// of session files, and it was wrong in a way that was measured rather than
/// suspected: a Claude session that is *thinking* writes nothing for 26
/// seconds, so the app called it idle while it was working. Widening the window
/// hid the symptom and kept the guess. An agent that reports `UserPromptSubmit`
/// and later `Stop` is not a guess.
///
/// The socket is read-only in this direction for now. Answering back — deciding
/// a permission request while the agent waits — is the same channel and a much
/// larger promise: an agent blocked on this app is an agent that stops working
/// if this app is wrong.
@MainActor
final class HookServer: ObservableObject {
    static let shared = HookServer()

    @Published private(set) var sessions: [AgentSession] = []

    private var listener: CInt = -1
    private var accepting: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.notchmon.hooks", qos: .utility)
    private var prune: Timer?


    private init() {}

    // MARK: Lifecycle

    func start() {
        guard listener < 0 else { return }
        let path = Bridge.socketPath
        guard path.utf8.count <= Bridge.maxPathLength else {
            Log.usage.error("hook socket path too long: \(path, privacy: .public)")
            return
        }

        // A socket file outlives the process that made it, so a crash leaves one
        // behind and the next bind fails with EADDRINUSE. Removing first is not
        // a race worth guarding: two copies of this app is already a bug.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self),
                        src, Bridge.maxPathLength)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            Log.usage.error("hook socket bind failed: \(errno, privacy: .public)")
            close(fd)
            return
        }
        // Nobody else's business. The events name workspaces and models.
        chmod(path, 0o700)
        guard listen(fd, 16) == 0 else { close(fd); return }

        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The descriptor is captured, not read back off the actor. Reaching
        // for main-actor state from the queue's handler is what made the first
        // version of this trap on the first event that ever arrived:
        // MainActor.assumeIsolated is an assertion, and it was false here.
        source.setEventHandler { Self.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        accepting = source

        Log.usage.info("hooks listening on \(path, privacy: .public)")
        armPrune()
    }

    func stop() {
        prune?.invalidate()
        prune = nil
        accepting?.cancel()
        accepting = nil
        if listener >= 0 { unlink(Bridge.socketPath) }
        listener = -1
    }

    // MARK: Reading

    /// Runs on `queue`, and touches nothing that belongs to the main actor.
    private nonisolated static func accept(on fd: CInt) {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }

        // The reader owns the descriptor from here.
        DispatchQueue.global(qos: .utility).async {
            defer { close(client) }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &chunk, chunk.count)
                guard n > 0 else { break }
                buffer.append(contentsOf: chunk[0..<n])
                // Newline-framed, so one connection may carry several events and
                // a partial tail waits for the rest rather than being decoded.
                while let end = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer = buffer[buffer.index(after: end)...]
                    guard !line.isEmpty,
                          let event = try? JSONDecoder.bridge.decode(HookEvent.self, from: Data(line))
                    else { continue }
                    Task { @MainActor in HookServer.shared.apply(event) }
                }
                // A sender that never sends a newline must not grow this without
                // bound.
                if buffer.count > 1 << 20 { break }
            }
        }
    }

    // MARK: State

    /// Folding an event into the session list.
    ///
    /// Separated from the socket so the part with the decisions in it can be
    /// tested without one.
    func apply(_ event: HookEvent) {
        sessions = Self.fold(event, into: sessions)
        Log.usage.info("""
            hook \(event.agent, privacy: .public)/\(event.event, privacy: .public)             -> \(event.status.rawValue, privacy: .public) (\(self.sessions.count, privacy: .public) live)
            """)
    }

    static func fold(_ event: HookEvent, into sessions: [AgentSession]) -> [AgentSession] {
        // No session id is not nothing: it still says an agent is alive. Keyed
        // on the terminal instead, which is the next most stable handle.
        guard let key = event.sessionID ?? event.tty else { return sessions }

        var out = sessions
        if event.status == .ended {
            out.removeAll { $0.id == key }
            return out
        }

        let session = AgentSession(
            id: key, agent: event.agent, status: event.status,
            workspace: event.workspace, model: event.model, tool: event.tool,
            tty: event.tty, pid: event.pid, updated: event.at)

        if let i = out.firstIndex(where: { $0.id == key }) {
            // Fields absent from this event keep their last known value: a
            // `Stop` carries no model, and blanking one on every stop would
            // make the panel flicker between knowing and not knowing.
            var merged = session
            merged.workspace = event.workspace ?? out[i].workspace
            merged.model = event.model ?? out[i].model
            merged.tool = event.tool ?? out[i].tool
            merged.tty = event.tty ?? out[i].tty
            out[i] = merged
        } else {
            out.append(session)
        }
        return out
    }

    static func pruned(_ sessions: [AgentSession], now: Date = Date(),
                       silence: TimeInterval = hookSessionSilence) -> [AgentSession] {
        sessions.filter { now.timeIntervalSince($0.updated) < silence }
    }

    private func armPrune() {
        prune = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let kept = Self.pruned(self.sessions)
                if kept.count != self.sessions.count { self.sessions = kept }
            }
        }
    }
}
