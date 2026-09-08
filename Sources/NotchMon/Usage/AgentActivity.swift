import Combine
import Foundation

/// Which agents are working right now.
///
/// An agent appends to its own session file every time it says something, so a
/// file touched seconds ago **is** that agent working. That is the whole
/// mechanism, and it has two properties worth the trouble: it needs no
/// cooperation from the agent, and it needs no list of agents in this code —
/// `tokscale clients` says where each one keeps its sessions, so a tool
/// tokscale learns about later lights up on its own.
///
/// Watched with FSEvents rather than polled: the kernel already knows, and a
/// timer walking five directories every second to ask it again would be paying
/// for an answer that is being given away.
///
/// What this cannot see is a long think, and the first version of this got the
/// consequence wrong. Measured on a working session, the gap between two writes
/// while the agent was thinking was **26 seconds** — so an eight-second window
/// went dark for eighteen of them, and with each agent lit for only eight
/// seconds after each write, two agents working at once almost never overlapped
/// and read as taking turns.
///
/// Process CPU was the obvious alternative and it does not separate the two: an
/// idle `claude` burns about 10 ms a second keeping its interface alive and a
/// working one about 21. Two times is not a threshold.
///
/// So there are two windows instead of one. Inside `lively` the agent has just
/// produced something; out to `settling` it is in the middle of a task and
/// merely quiet. Both animate — the second one slower and dimmer — because the
/// alternative is an indicator that blinks off mid-task, which is worse than
/// one that lingers a little after.
/// How alive an agent looks.
enum ActivityLevel: Equatable {
    /// Wrote a moment ago.
    case lively
    /// In a task and quiet — thinking, or waiting on a tool.
    case settling

    /// Multiplier on the animation's cycle. Slower while quiet, so the two
    /// states are told apart by rhythm as well as by brightness.
    var pace: Double { self == .lively ? 1 : 1.9 }
    var opacity: Double { self == .lively ? 1 : 0.5 }

    /// Just produced something.
    static let livelyWindow: TimeInterval = 12
    /// In the middle of a task, and quiet. Wide enough to cover the measured
    /// 26-second thinking gap with room over it; short enough that a session
    /// you have finished with stops moving while you are still looking at it.
    static let settlingWindow: TimeInterval = 50

    /// Nil once an agent has been quiet long enough to be done.
    static func at(quietFor seconds: TimeInterval) -> ActivityLevel? {
        if seconds <= livelyWindow { return .lively }
        if seconds <= settlingWindow { return .settling }
        return nil
    }
}

@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()

    @Published private(set) var levels: [Brand: ActivityLevel] = [:]

    private var lastWrite: [Brand: Date] = [:]
    private var roots: [(brand: Brand, prefix: String)] = []
    private var stream: FSEventStreamRef?
    private var decay: Timer?

    private init() {}

    // MARK: Lifecycle

    func start() {
        Task { [weak self] in
            let roots = await Self.sessionRoots()
            await MainActor.run { self?.watch(roots) }
        }
    }

    func stop() {
        decay?.invalidate()
        decay = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Asks tokscale where every client it knows keeps its sessions.
    private static func sessionRoots() async -> [(brand: Brand, prefix: String)] {
        guard let clients = try? await Tokscale.shared.sessionLocations() else { return [] }
        return clients.map { (Brand.match($0.client), $0.path) }
    }

    private func watch(_ roots: [(brand: Brand, prefix: String)]) {
        stop()
        self.roots = roots
        guard !roots.isEmpty else {
            Log.usage.info("no session roots to watch; the strip will not show activity")
            return
        }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // `FileEvents` so a write to one session file is reported as that file
        // rather than as its directory; `NoDefer` so the first event of a burst
        // arrives at once and the strip lights up as work starts, not half a
        // second later.
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, paths, _, _ in
                guard let info,
                      // Only a CFArray because `UseCFTypes` is set below.
                      // Without that flag this argument is a C array of C
                      // strings and reading it as an array of CFString is
                      // reading whatever happens to be in that memory.
                      let list = unsafeBitCast(paths, to: NSArray.self) as? [String]
                else { return }
                let activity = Unmanaged<AgentActivity>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { activity.saw(list) }
            },
            &context,
            roots.map(\.prefix) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagNoDefer
                                     | kFSEventStreamCreateFlagUseCFTypes))

        guard let created else {
            Log.usage.error("could not watch session roots; the strip will not show activity")
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
        Log.usage.info("watching \(roots.count, privacy: .public) session roots")
    }

    // MARK: Reading the events

    private func saw(_ paths: [String]) {
        let now = Date()
        var changed = false
        for path in paths {
            // Longest prefix wins: one client's root can sit inside another's.
            guard let brand = roots
                .filter({ path.hasPrefix($0.prefix) })
                .max(by: { $0.prefix.count < $1.prefix.count })?.brand
            else { continue }
            lastWrite[brand] = now
            changed = true
        }
        guard changed else { return }
        refresh()
    }

    /// Recomputes the levels and keeps a one-second tick running only while
    /// something is in them — so an idle machine pays nothing at all.
    private func refresh() {
        let now = Date()
        var live: [Brand: ActivityLevel] = [:]
        for (brand, written) in lastWrite {
            live[brand] = ActivityLevel.at(quietFor: now.timeIntervalSince(written))
        }
        if live != levels { levels = live }

        if live.isEmpty {
            decay?.invalidate()
            decay = nil
        } else if decay == nil {
            decay = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
}
