import Foundation

/// One admitted quota reading.
///
/// `at` is the real observation time, never a grid position — the poll runs on
/// its own clock and a refresh can be skipped or rate-limited, so the points
/// are unevenly spaced by construction and every consumer has to cope with that.
struct QuotaSample: Codable, Equatable {
    let at: Date
    let usedPercent: Double
    /// The reset the provider reported at the moment of the reading. Stored per
    /// sample rather than per cycle: a provider can revise it, and the revision
    /// is what tells us a new cycle started.
    let resetAt: Date
}

/// Where a window's length came from.
///
/// Named rather than inferred at the point of use, because the three are not
/// equally trustworthy and the difference decides whether a projection is worth
/// drawing. Modelled on TokenBar's `DurationSource` (MIT — see THIRD_PARTY.md).
enum QuotaDurationSource: String, Codable {
    /// Watched two consecutive resets and measured the gap. Ground truth.
    case observed
    /// Read off the window's own name — "5-hour", "7-day", "Weekly".
    case contract
}

/// How long a quota window runs.
///
/// tokscale reports only `resets_at`, the window's END. Everything downstream
/// needs its START, so the length has to come from somewhere else.
struct QuotaDuration: Codable, Equatable {
    let seconds: TimeInterval
    let source: QuotaDurationSource

    /// Longer than any window a vendor plausibly meters, and short enough that
    /// a garbage reading cannot project a century into the future.
    static let maximum: TimeInterval = 400 * 86_400
    /// No vendor meters a window shorter than this. The floor exists to
    /// reject a measurement, not to describe a plan.
    static let minimum: TimeInterval = 15 * 60

    var isPlausible: Bool { seconds >= Self.minimum && seconds <= Self.maximum }
}

/// The stored series for one provider's one window.
struct QuotaSeries: Codable {
    var samples: [QuotaSample]
    /// The last length measured by watching a reset move. Kept even when the
    /// current cycle has not produced one, because a window's length does not
    /// change between cycles and re-deriving it from the label would be a
    /// downgrade.
    var observedSeconds: TimeInterval?
    var lastActivityAt: Date

    static let empty = QuotaSeries(samples: [], observedSeconds: nil, lastActivityAt: .distantPast)
}

/// Quota readings kept over time, so the panel can say where a window is
/// *heading* rather than only where it is.
///
/// tokscale answers "how much is left right now" and nothing else — there is no
/// history in it, and none of the three other Swift notch apps keep any either.
/// Without a curve the only honest thing a panel can say about a limit is its
/// current level, which is why every one of them stops there.
///
/// Deliberately a plain JSON file rather than `UserDefaults`: this grows with
/// every poll, and defaults are read into memory wholesale by every process
/// that touches the domain.
@MainActor
final class QuotaHistory {
    static let shared = QuotaHistory()

    private var store: [String: QuotaSeries] = [:]
    private var isLoaded = false
    private var saveWork: DispatchWorkItem?

    /// A window is identified by who reports it and what it is called. Account
    /// is not in the key yet — tokscale collapses multiple Claude profiles into
    /// one "Claude", so there is nothing here to tell them apart. If that
    /// changes, the account goes in here and nowhere else.
    static func key(provider: String, label: String) -> String { "\(provider)|\(label)" }

    // MARK: Retention

    /// Long enough to hold several cycles of a weekly window, which is what a
    /// projection needs to be worth anything; short enough that the file stays
    /// a few tens of kilobytes.
    private static let retention: TimeInterval = 60 * 86_400
    /// A hard stop per series, so a pathological poll loop cannot grow the file
    /// without bound. At the default three-minute quota poll this is about ten
    /// days of samples, and the fold only ever reads the newest cycle.
    private static let maximumSamples = 4_000
    /// Closest two admitted samples may sit. Stops a run of manual refreshes
    /// from over-weighting one moment; a rollover is admitted regardless, since
    /// a cycle boundary is a fact no interval should hide.
    private static let minimumSampleGap: TimeInterval = 60

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NotchMon", isDirectory: true)
            .appendingPathComponent("quota-history.json")
    }

    // MARK: Reading and writing

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            store = try JSONDecoder().decode([String: QuotaSeries].self, from: data)
            Log.usage.info("quota history loaded: \(self.store.count, privacy: .public) series")
        } catch {
            // A file this app wrote and cannot read is a schema change, not a
            // user problem. Starting over costs a few days of curve and is
            // silent; refusing to start costs the feature entirely.
            Log.usage.error("quota history unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            store = [:]
        }
    }

    /// Coalesced, because a refresh writes every series at once and each one
    /// would otherwise re-encode and re-write the whole file.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(store)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.usage.error("quota history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func flush() {
        saveWork?.cancel()
        saveWork = nil
        if isLoaded { save() }
    }

    // MARK: Recording

    /// Files one reading, and notices when the window has rolled over.
    ///
    /// The rollover is the only place a window's true length can be learned:
    /// the provider hands over an end and never a start, so the gap between two
    /// consecutive ends *is* the duration. It is measured rather than assumed
    /// because a plan change or a vendor quietly redefining "weekly" would
    /// otherwise go unnoticed for as long as the app is installed.
    func record(provider: String, metric: UsageMetric, at now: Date = Date()) {
        loadIfNeeded()
        guard !metric.hasNoAllowance,
              let used = metric.usedPercent,
              let resetAt = metric.resetDate
        else { return }

        let key = Self.key(provider: provider, label: metric.label)
        var series = store[key] ?? .empty

        if let previousReset = series.samples.last?.resetAt, resetAt > previousReset,
           let measured = Self.observedDuration(
            jump: resetAt.timeIntervalSince(previousReset), label: metric.label) {
            series.observedSeconds = measured
            Log.usage.info(
                "observed \(key, privacy: .public) window: \(Int(measured / 60), privacy: .public)m")
        }

        // Admission is by TIME, never by value — and the difference is the
        // whole correctness of the flat state.
        //
        // Skipping a reading because it repeats the last one sounds like
        // avoiding noise, and does the opposite: burn all morning, stop, and
        // every afternoon poll reads the same percentage and is dropped. The
        // newest admitted sample stays the morning one, the lookback span still
        // sees the morning's climb, and the fold projects a burn that ended
        // hours ago. A window nobody has touched since breakfast reads as
        // running out.
        //
        // Repeated readings are exactly what makes a slope flatten, which is
        // the correct answer when nothing is moving. So they are kept, and only
        // a burst inside one minute is turned away — that is a manual refresh
        // being clicked, not a new fact.
        if let last = series.samples.last,
           now.timeIntervalSince(last.at) < Self.minimumSampleGap,
           last.resetAt == resetAt {
            return
        }

        series.samples.append(QuotaSample(at: now, usedPercent: used, resetAt: resetAt))
        series.lastActivityAt = now
        prune(&series, now: now)
        store[key] = series
        scheduleSave()
    }

    /// A jump in the reset time, judged against what the window is called.
    ///
    /// "The reset moved, so a cycle ended" is the obvious rule and it is wrong
    /// for half these providers. A **fixed** window holds its reset for the whole
    /// cycle and then jumps by one window length; a **rolling** one slides its
    /// reset forward continuously, so the gap between two consecutive readings
    /// is the poll interval. Taking that gap as the duration measured Codex's
    /// five-hour window at one minute — and a one-minute window puts its own
    /// start five hours in the future, which silently switched Codex's
    /// projections off rather than making them wrong, which is worse.
    ///
    /// So a jump only counts as a rollover when it is about the length the
    /// window's own name implies, and a window whose name means nothing to us
    /// is never observed at all. Observation refines a contract here; it does
    /// not invent one.
    nonisolated static func observedDuration(jump: TimeInterval, label: String) -> TimeInterval? {
        guard let contract = contractDuration(label: label) else { return nil }
        guard jump >= contract.seconds * 0.5, jump <= contract.seconds * 2 else { return nil }
        return QuotaDuration(seconds: jump, source: .observed).isPlausible ? jump : nil
    }

    /// Whether a stored measurement still stands up against the contract.
    ///
    /// Applied on read as well as on write, so a bad value written by an
    /// earlier build heals itself on the next launch instead of needing the
    /// file deleted.
    nonisolated static func isCredible(_ seconds: TimeInterval, label: String) -> Bool {
        guard QuotaDuration(seconds: seconds, source: .observed).isPlausible else { return false }
        guard let contract = contractDuration(label: label) else { return true }
        return seconds >= contract.seconds * 0.5 && seconds <= contract.seconds * 2
    }

    private func prune(_ series: inout QuotaSeries, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        if series.samples.first.map({ $0.at < cutoff }) == true {
            series.samples.removeAll { $0.at < cutoff }
        }
        if series.samples.count > Self.maximumSamples {
            series.samples.removeFirst(series.samples.count - Self.maximumSamples)
        }
    }

    // MARK: Reading back

    func samples(provider: String, label: String) -> [QuotaSample] {
        loadIfNeeded()
        return store[Self.key(provider: provider, label: label)]?.samples ?? []
    }

    /// How long this window runs — measured if a reset has ever been watched,
    /// otherwise read off its name.
    func duration(provider: String, label: String) -> QuotaDuration? {
        loadIfNeeded()
        let key = Self.key(provider: provider, label: label)
        if let seconds = store[key]?.observedSeconds {
            if Self.isCredible(seconds, label: label) {
                return QuotaDuration(seconds: seconds, source: .observed)
            }
            store[key]?.observedSeconds = nil
            Log.usage.error("discarded implausible observed window for \(key, privacy: .public)")
        }
        return Self.contractDuration(label: label)
    }

    /// The window's length as its own name states it.
    ///
    /// A fallback, and only that: it holds until the first rollover is watched,
    /// and it covers what these vendors actually call their windows rather than
    /// trying to be a general parser. Anything it does not recognise gets no
    /// projection at all, which is the correct answer — a guessed duration
    /// produces a confidently wrong slope, and that is worse than a blank.
    nonisolated static func contractDuration(label: String) -> QuotaDuration? {
        let name = label.lowercased().trimmingCharacters(in: .whitespaces)
        let hour: TimeInterval = 3_600, day: TimeInterval = 86_400

        // Claude and Codex both meter a rolling five hours; Claude calls it
        // "Session", Codex "5h".
        if name.contains("session") { return QuotaDuration(seconds: 5 * hour, source: .contract) }
        if name.contains("week") { return QuotaDuration(seconds: 7 * day, source: .contract) }
        if name.contains("month") || name.contains("premium") {
            return QuotaDuration(seconds: 30 * day, source: .contract)
        }
        if name.contains("dai") { return QuotaDuration(seconds: day, source: .contract) }

        // "5-hour", "5h", "7-day", "30d" — a count and a unit.
        let scanner = Scanner(string: name)
        if let value = scanner.scanDouble() {
            let rest = name[name.index(name.startIndex, offsetBy: scanner.currentIndex.utf16Offset(in: name))...]
            let unit = rest.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            if unit.hasPrefix("h") { return QuotaDuration(seconds: value * hour, source: .contract) }
            if unit.hasPrefix("d") { return QuotaDuration(seconds: value * day, source: .contract) }
            if unit.hasPrefix("w") { return QuotaDuration(seconds: value * 7 * day, source: .contract) }
            if unit.hasPrefix("m") { return QuotaDuration(seconds: value * 30 * day, source: .contract) }
        }
        return nil
    }
}
