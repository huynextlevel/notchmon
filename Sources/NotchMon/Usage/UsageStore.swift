import AppKit
import Combine
import Foundation

/// Polls tokscale and publishes what the notch draws.
///
/// Quotas and the token scan are kept on separate clocks and separate error
/// slots on purpose: the scan reads local files and effectively always works,
/// while the quota call talks to five different vendors' endpoints and fails
/// piecemeal. One going dark must not blank the other.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var providers: [ProviderSnapshot] = []
    @Published private(set) var today: ScanReport = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var scanError: String?
    @Published private(set) var lastUpdated: Date?
    /// Last hour each tokscale client was active, from the weekly hourly report.
    @Published private(set) var lastActive: [String: Date] = [:]
    /// A year of daily totals, for the activity grid.
    @Published private(set) var activity: [ContributionDay] = []
    @Published private(set) var activeDays: Int = 0
    /// Today's spend per project — the Projects page.
    @Published private(set) var projects: [ProjectUsage] = []
    /// The most recent window to cross the user's warning threshold. Published
    /// so the notch can react; cleared by whoever reacted.
    @Published private(set) var warning: QuotaWarning?

    /// Which windows have already been warned about, kept across launches so a
    /// restart does not re-announce a quota you were told about this morning.
    private var alerts = AlertLedger(warned: Set(
        UserDefaults.standard.stringArray(forKey: "warnedWindows") ?? []))

    /// Resolved once from `tokscale --help`, then reused. Nil until the first
    /// successful probe.
    private var supportedClients: [String]?
    private var quotaTimer: Timer?
    private var scanTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// When worktree merging may be attempted again.
    ///
    /// It used to be a Bool cleared for the whole session, and that was the
    /// wrong shape: the timeout lands at *launch*, when three tokscale
    /// processes start at once against a cold cache, and warm it answers in
    /// about a second. One slow start therefore cost the entire day — which
    /// mattered more than it looks, because the unmerged form is also the one
    /// that reports client-native workspace keys.
    private var mergeWorktreesAfter = Date.distantPast
    private var quotaTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// The order providers appear in, so the notch does not reshuffle itself
    /// every refresh just because a percentage crossed another one.
    private static let preferredOrder = [
        "Claude", "Codex", "Cursor", "Copilot", "Gemini", "Antigravity",
        "GLM", "Grok", "OpenRouter", "Minimax", "Kimi", "DeepSeek"
    ]

    func start() {
        loadRoster()
        refresh()
        armQuotaTimer(every: Preferences.shared.quotaInterval)
        armScanTimer(every: Preferences.shared.scanInterval)

        // The two intervals are live settings, not a snapshot taken at launch.
        // They used to be read once, right here, so choosing "1m" in Settings
        // wrote a number to disk and changed nothing until the next relaunch.
        //
        // The interval comes from the publisher rather than being read back off
        // `Preferences`: `@Published` emits from `willSet`, so a handler that
        // reads the property is reading the value being replaced.
        Preferences.shared.$quotaInterval.dropFirst().removeDuplicates()
            .sink { [weak self] interval in
                MainActor.assumeIsolated { self?.armQuotaTimer(every: interval) }
            }
            .store(in: &cancellables)
        Preferences.shared.$scanInterval.dropFirst().removeDuplicates()
            .sink { [weak self] interval in
                MainActor.assumeIsolated { self?.armScanTimer(every: interval) }
            }
            .store(in: &cancellables)
    }

    /// Both clocks run for as long as the app does, whether or not the notch is
    /// open: the strip beside the notch is on screen all day and has to be
    /// current without being asked.
    private func armQuotaTimer(every interval: TimeInterval) {
        quotaTimer?.invalidate()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuotas() }
        }
        Log.usage.info("quota clock: every \(Int(interval), privacy: .public)s")
    }

    private func armScanTimer(every interval: TimeInterval) {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshScan() }
        }
        Log.usage.info("scan clock: every \(Int(interval), privacy: .public)s")
    }

    func stop() {
        QuotaHistory.shared.flush()
        quotaTimer?.invalidate()
        scanTimer?.invalidate()
        quotaTask?.cancel()
        scanTask?.cancel()
    }

    /// Refreshes, unless the last one is recent enough that nothing could have
    /// changed. Opening the notch asks for a refresh, and without this a few
    /// seconds of hovering in and out would spawn a tokscale scan per hover —
    /// against endpoints that rate-limit, for numbers that move in minutes.
    func refresh(force: Bool = false) {
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < Self.minimumRefreshGap {
            return
        }
        refreshQuotas()
        refreshScan()
    }

    /// Long enough to absorb a burst of hovers, short enough that opening the
    /// notch after a coffee still shows current numbers.
    private static let minimumRefreshGap: TimeInterval = 45

    // MARK: Quotas

    private func refreshQuotas() {
        // A refresh already in flight is left alone rather than restarted: the
        // call is slow and rate-limited, and cancelling it to start an
        // identical one would only push the answer further away.
        guard quotaTask == nil else { return }
        isRefreshing = true
        quotaTask = Task { [weak self] in
            defer { Task { @MainActor in self?.quotaTask = nil; self?.settleRefreshing() } }
            do {
                let raw = try await Tokscale.shared.quotas()
                await MainActor.run {
                    // Record before merging: the merge can carry a provider
                    // forward from a previous fetch, and a carried-forward
                    // reading is not a new observation. Only what the provider
                    // just said goes into the curve.
                    self?.recordSamples(from: raw)
                    let snapshots = self?.merge(Self.snapshots(from: raw)) ?? []
                    self?.providers = snapshots
                    self?.quotaError = nil
                    self?.lastUpdated = Date()
                    self?.checkWarnings()
                    let projected = snapshots.reduce(0) { $0 + $1.trends.count }
                    let atRisk = snapshots.filter(\.headlineRunsOutEarly).count
                    Log.usage.info(
                        "quotas ok: \(snapshots.count, privacy: .public) providers, \(projected, privacy: .public) projected, \(atRisk, privacy: .public) at risk")
                }
            } catch {
                await MainActor.run {
                    self?.quotaError = error.localizedDescription
                    Log.usage.error("quota refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: A provider that vanishes is not a provider you signed out of

    /// The last good answer per provider, so a fetch that comes back short does
    /// not blank a row. Survives a relaunch — see `loadRoster`.
    private var lastGood: [String: ProviderSnapshot] = [:]

    private static let rosterKey = "providerRoster"

    /// Reads the roster written by the previous run.
    ///
    /// Without this the merge only helps once a provider has been seen in THIS
    /// process, and a cold start that misses is a panel with your main provider
    /// simply absent for the first three minutes — which is the exact impression
    /// the merge exists to prevent. Numbers restored this way arrive stale and
    /// say so; what is really being restored is the ROSTER, the knowledge of
    /// which providers you are signed into, and that does not change between
    /// launches.
    private func loadRoster() {
        guard let data = UserDefaults.standard.data(forKey: Self.rosterKey),
              let saved = try? JSONDecoder().decode([ProviderSnapshot].self, from: data)
        else { return }
        let now = Date()
        for snapshot in saved where now.timeIntervalSince(snapshot.seenAt) < Self.staleHorizon {
            lastGood[snapshot.provider] = snapshot
        }
        providers = merge([])
    }

    private func saveRoster() {
        guard let data = try? JSONEncoder().encode(Array(lastGood.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.rosterKey)
    }

    /// How long a provider keeps its slot after it stops being reported.
    ///
    /// tokscale's Claude call comes back empty every few polls — the same binary,
    /// a minute apart, returns three providers and then two. Deleting the row on
    /// each miss makes the panel flicker between layouts, and worse, makes a
    /// transient fetch failure look identical to an account you never had. A day
    /// is long enough that no amount of flakiness blanks a live account, and
    /// short enough that one you genuinely signed out of is gone by tomorrow.
    private static let staleHorizon: TimeInterval = 24 * 60 * 60

    /// Keeps providers the fetch dropped, marked stale, and forgets the ones
    /// that have been gone long enough to be gone for real.
    private func merge(_ fresh: [ProviderSnapshot]) -> [ProviderSnapshot] {
        for snapshot in fresh { lastGood[snapshot.provider] = snapshot }
        let names = Set(fresh.map(\.provider))
        let now = Date()
        var kept = fresh
        for (name, previous) in lastGood where !names.contains(name) {
            guard now.timeIntervalSince(previous.seenAt) < Self.staleHorizon else {
                lastGood[name] = nil
                continue
            }
            kept.append(
                ProviderSnapshot(
                    provider: previous.provider,
                    plan: previous.plan,
                    email: previous.email,
                    metrics: previous.metrics,
                    freeResets: previous.freeResets,
                    seenAt: previous.seenAt,
                    isStale: true
                )
            )
        }
        saveRoster()
        return withTrends(Self.sorted(kept))
    }

    // MARK: Pace

    private func recordSamples(from raw: [ProviderUsage]) {
        for provider in raw {
            for metric in provider.metrics {
                QuotaHistory.shared.record(provider: provider.provider, metric: metric)
            }
        }
    }

    /// Attaches the recent pace of each window to the snapshot that draws it.
    ///
    /// Derived here rather than inside `ProviderSnapshot` because it needs the
    /// recorded history, and a model that reaches for a store is a model you
    /// cannot construct in a test.
    private func withTrends(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let now = Date()
        return snapshots.map { snapshot in
            var updated = snapshot
            var trends: [String: QuotaTrend] = [:]
            for metric in snapshot.meteredMetrics {
                guard let used = metric.usedPercent,
                      let resetAt = metric.resetDate,
                      let duration = QuotaHistory.shared.duration(
                        provider: snapshot.provider, label: metric.label)
                else { continue }
                let samples = QuotaHistory.shared.samples(
                    provider: snapshot.provider, label: metric.label)
                if let trend = QuotaTrendFold.trend(
                    usedPercent: used,
                    windowStart: resetAt.addingTimeInterval(-duration.seconds),
                    windowEnd: resetAt,
                    now: now,
                    samples: samples
                ) {
                    trends[metric.label] = trend
                }
            }
            updated.trends = trends
            return updated
        }
    }

    private static func snapshots(from raw: [ProviderUsage]) -> [ProviderSnapshot] {
        raw
            .map {
                ProviderSnapshot(
                    provider: $0.provider,
                    plan: $0.plan,
                    email: $0.email,
                    metrics: $0.metrics,
                    freeResets: $0.resetCredits?.availableCount ?? 0,
                    seenAt: Date(),
                    isStale: false
                )
            }
            // A provider with no windows at all has nothing to draw and would
            // only take up a slot beside the notch. Together with tokscale
            // reporting only the accounts it can read, this is what keeps the
            // panel to providers you are actually signed into — there is no
            // "Not signed in" row here and there should not be one.
            .filter { !$0.metrics.isEmpty }
    }

    private static func sorted(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.sorted { lhs, rhs in
            let left = preferredOrder.firstIndex(of: lhs.provider) ?? Int.max
            let right = preferredOrder.firstIndex(of: rhs.provider) ?? Int.max
            if left != right { return left < right }
            return lhs.provider < rhs.provider
        }
    }

    // MARK: Token scan

    /// Four tokscale calls, each published the moment it lands.
    ///
    /// They used to be gathered and assigned together at the end, which made
    /// the slowest one the speed of all four — and worse than slow: a call can
    /// *block*. tokscale reads workspace paths, some of which live under a
    /// TCC-protected folder, and a child process inherits this app's
    /// permissions. With a consent prompt outstanding the read does not fail,
    /// it waits — and a single waiting call held back today's totals, the
    /// activity year and the recency map, all of which had already been
    /// fetched. The panel read "Nothing recorded today" while the answer was
    /// sitting in a local variable.
    private func refreshScan() {
        guard scanTask == nil else { return }
        isRefreshing = true
        scanTask = Task { [weak self] in
            defer { Task { @MainActor in self?.scanTask = nil; self?.settleRefreshing() } }
            let clients = await self?.resolvedClients() ?? ""

            do {
                let report = try await Tokscale.shared.todayScan(clients: clients)
                await MainActor.run {
                    self?.today = report
                    self?.scanError = nil
                    self?.lastUpdated = Date()
                    Log.usage.info("scan ok: \(report.entries.count, privacy: .public) entries, $\(report.totalCost, privacy: .public)")
                }
            } catch {
                await MainActor.run {
                    self?.scanError = error.localizedDescription
                    Log.usage.error("scan failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            // The three that ride along. Each answers the same question at a
            // different grain — the project, the year, the last time — and each
            // fails on its own without taking the others with it.
            if let report = await self?.projectReport(clients: clients) {
                let projects = ProjectUsage.fold(report)
                await MainActor.run {
                    if !projects.isEmpty { self?.projects = projects }
                    Log.usage.info("projects: \(projects.count, privacy: .public)")
                }
            }

            if let graph = try? await Tokscale.shared.graph(clients: clients) {
                await MainActor.run {
                    self?.activity = graph.contributions
                    self?.activeDays = graph.summary.activeDays
                }
            }

            if let seen = try? await Tokscale.shared.recentActivity(), !seen.isEmpty {
                await MainActor.run { self?.lastActive = seen }
            }
        }
    }

    /// Folding git worktrees is worth having and must never cost the page.
    ///
    /// `--merge-worktrees` is the one call that reads the filesystem, so it is
    /// also the one that can be stopped by macOS's file-access consent. A
    /// refused read fails and a *pending* one blocks, and blocking is the worse
    /// of the two: the panel sat on "Nothing recorded today" with a spinner
    /// while every other figure on screen was current.
    ///
    /// So the merged form gets one attempt on a short leash. If it does not
    /// come back, the plain form runs instead — worktrees show as separate
    /// rows, which is a smaller loss than an empty page — and the merged form
    /// is not asked for again this session.
    /// Long enough that a cold start is over, short enough that a session does
    /// not spend the day in the fallback.
    static let mergeBackoff: TimeInterval = 10 * 60

    private func projectReport(clients: String) async -> ProjectReport? {
        if Date() >= mergeWorktreesAfter {
            if let merged = try? await Tokscale.shared.projectScan(
                clients: clients, mergeWorktrees: true, timeout: 8) {
                return merged
            }
            mergeWorktreesAfter = Date().addingTimeInterval(Self.mergeBackoff)
            Log.usage.error("merge-worktrees did not answer; retrying in \(Int(Self.mergeBackoff / 60), privacy: .public)m")
        }
        return try? await Tokscale.shared.projectScan(
            clients: clients, mergeWorktrees: false, timeout: 90)
    }

    /// The `--client` filter to pass. An explicit preference wins; otherwise
    /// the binary's own list is used, so a tokscale upgrade that adds tools
    /// picks them up without a code change here.
    private func resolvedClients() async -> String {
        let configured = Preferences.shared.clients.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        if let known = supportedClients { return known.joined(separator: ",") }
        do {
            let probed = try await Tokscale.shared.supportedClients()
            supportedClients = probed
            return probed.joined(separator: ",")
        } catch {
            Log.usage.error("client probe failed: \(error.localizedDescription, privacy: .public)")
            // An empty filter means "no --client flag", which tokscale reads as
            // all of them — the same intent, just without the explicit list.
            return ""
        }
    }

    // MARK: Recency

    /// When a provider's brand was last active, across every client that
    /// spends against it.
    func lastUsed(_ snapshot: ProviderSnapshot) -> Date? {
        lastActive.filter { Brand.match($0.key) == snapshot.brand }.values.max()
    }

    /// Providers with something to say first: the ones used most recently,
    /// then the rest in their usual order.
    ///
    /// The strip takes the head of this list. A quota you hold but have not
    /// touched all week — a Copilot plan that came with a GitHub account — is
    /// still a quota, and the panel still lists it, but it has no business
    /// occupying one of two slots beside the notch.
    var providersByRecency: [ProviderSnapshot] {
        let used = visibleProviders
            .compactMap { snapshot in lastUsed(snapshot).map { (snapshot, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let idle = visibleProviders.filter { snapshot in !used.contains { $0.id == snapshot.id } }
        return used + idle
    }

    /// Agents the user has not switched off.
    /// Announces a window that has just crossed the threshold, at most once.
    ///
    /// Only visible providers: an agent switched off in Settings is one the
    /// user has said they are not tracking, and warning about it anyway would
    /// make the toggle a lie.
    private func checkWarnings() {
        alerts.prune()
        let crossings = alerts.crossings(
            in: visibleProviders, threshold: Preferences.shared.warnAtPercent)
        UserDefaults.standard.set(Array(alerts.warned), forKey: "warnedWindows")
        // The worst one, if several cross at once — a single flash cannot say
        // two things, and the fuller window is the one that bites first.
        guard let worst = crossings.max(by: { $0.spentPercent < $1.spentPercent }) else { return }
        Log.usage.info(
            "warn: \(worst.provider, privacy: .public) \(worst.label, privacy: .public) at \(worst.spentPercent, privacy: .public)%")
        warning = worst
    }

    func clearWarning() { warning = nil }

    var visibleProviders: [ProviderSnapshot] {
        let hidden = Preferences.shared.hiddenAgents
        return Self.padded(providers.filter { !hidden.contains($0.provider) })
    }

    /// Development affordance: `NOTCHMON_FAKE_AGENTS=10` pads the roster with
    /// invented agents.
    ///
    /// Here rather than in a test because the thing it exercises is a *layout*,
    /// and a layout that only fails at ten agents cannot be seen on a machine
    /// that has two. Same reason `NOTCHMON_OPEN_PAGE` exists: some faults are
    /// only visible on the real panel.
    ///
    /// Spread across the whole range on purpose. A layout tried only in the
    /// comfortable middle never meets the row at 4% that has to turn red, or
    /// the one at 100% with nothing to say.
    private static func padded(_ real: [ProviderSnapshot]) -> [ProviderSnapshot] {
        guard let raw = ProcessInfo.processInfo.environment["NOTCHMON_FAKE_AGENTS"],
              let want = Int(raw), want > real.count
        else { return real }
        let invented: [(String, Double, String)] = [
            ("Copilot", 62, "18d"), ("Gemini", 4, "2h 10m"), ("Cursor", 100, "21d"),
            ("Amp", 47, "6h"), ("Droid", 88, "3d 4h"), ("Kimi", 12, "55m"),
            ("Qwen", 71, "12h"), ("Crush", 33, "1d 6h"), ("Goose", 96, "9d"),
            ("Zed", 25, "4h 40m"), ("Cline", 58, "2d"), ("Warp", 8, "31m")
        ]
        let taken = Set(real.map(\.provider))
        let extras = invented
            .filter { !taken.contains($0.0) }
            .prefix(want - real.count)
            .map { name, left, _ in
                ProviderSnapshot(
                    provider: name, plan: "Test", email: nil,
                    metrics: [UsageMetric(label: "5-hour", usedPercent: 100 - left,
                                          remainingPercent: left, remainingLabel: nil,
                                          resetsAt: nil)],
                    freeResets: 0, seenAt: Date(), isStale: false)
            }
        return real + Array(extras)
    }

    /// The two beside the notch: pinned first, then most recently used.
    ///
    /// Two, because the menu bar's left strip has to stay clear for the app's
    /// own menus and a third figure is what starts pushing into them. A quota
    /// you hold but have not touched all week still appears in the panel; it
    /// has no business occupying one of two slots.
    var stripProviders: [ProviderSnapshot] {
        let pinned = Preferences.shared.pinnedAgents
        let ordered = providersByRecency.filter { !Preferences.shared.hiddenAgents.contains($0.provider) }
        return Array(
            (ordered.filter { pinned.contains($0.provider) }
             + ordered.filter { !pinned.contains($0.provider) }).prefix(2))
    }

    private func settleRefreshing() {
        isRefreshing = quotaTask != nil || scanTask != nil
    }
}
