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
/// What this cannot see: a long think with no output looks exactly like idle.
/// So the window is a trailing one — an agent counts as working until it has
/// been quiet for `window` seconds — rather than a strict "wrote in the last
/// frame". An indicator that flickered during normal work would be worse than
/// no indicator.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()

    /// Long enough to bridge a pause for thought, short enough that a finished
    /// session stops looking busy while you are still watching the strip.
    private let window: TimeInterval = 8

    @Published private(set) var working: Set<Brand> = []

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

    /// Recomputes the set and keeps a one-second tick running only while
    /// something is in it — so an idle machine pays nothing at all.
    private func refresh() {
        let cutoff = Date().addingTimeInterval(-window)
        let live = Set(lastWrite.filter { $0.value > cutoff }.keys)
        if live != working { working = live }

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
