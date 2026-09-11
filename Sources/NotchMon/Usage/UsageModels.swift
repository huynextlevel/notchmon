import Foundation

// MARK: - Quota (`tokscale usage --json`)

/// One quota window a provider reports: Claude's "Session"/"Weekly", Codex's
/// "5h"/"Weekly", Copilot's "Premium", and so on.
///
/// `used_percent` is the only field every provider fills in, so it is what the
/// ring is drawn from; the rest are decoration when present.
struct UsageMetric: Codable, Hashable {
    let label: String
    let usedPercent: Double?
    let remainingPercent: Double?
    let remainingLabel: String?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case remainingLabel = "remaining_label"
        case resetsAt = "resets_at"
    }

    /// Clamped, because a provider that reports 103% must not overdraw the ring.
    var fraction: Double { min(max((usedPercent ?? 0) / 100, 0), 1) }

    /// What is LEFT, which is the number the panel prints.
    ///
    /// Every surface in this app says "left" rather than "used", and it is one
    /// decision, not a formatting preference: the question you open the notch to
    /// answer is "can I keep going", and that is a question about headroom. A
    /// panel that mixes the two — a ring filling up beside a figure counting
    /// down — makes you do the subtraction yourself, every glance.
    ///
    /// `remaining_percent` is preferred over `100 - used` because a provider
    /// that reports both is the authority on its own rounding.
    var remainingFraction: Double {
        if let remaining = remainingPercent { return min(max(remaining / 100, 0), 1) }
        return 1 - fraction
    }

    /// Some windows exist on the account but carry no allowance at all — GitHub
    /// Copilot reports Chat and Completions as `0/0 left` on the Individual plan.
    ///
    /// Left alone this is the single most misleading thing the data can do: the
    /// provider says `used_percent: 0`, the app prints "100% left", and the row
    /// reads healthiest exactly where there is nothing to spend. So it gets its
    /// own state and its own words.
    var hasNoAllowance: Bool {
        guard let label = remainingLabel else { return false }
        let parts = label.split(separator: " ").first?.split(separator: "/") ?? []
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { Int($0) == 0 }
    }

    /// `1500/1500 left` → `1500/1500`. The exact count when the provider gives
    /// one: a percentage is a summary, and "3 premium requests left" is a fact.
    var countText: String? {
        guard let label = remainingLabel, !hasNoAllowance else { return nil }
        let head = label.replacingOccurrences(of: " left", with: "")
        return head.isEmpty ? nil : head
    }

    /// `resets_at` arrives in two shapes — a full ISO-8601 stamp with fractional
    /// seconds (Claude, Codex) and a bare `YYYY-MM-DD` (Copilot) — so both are
    /// tried rather than assuming the richer one.
    var resetDate: Date? {
        guard let raw = resetsAt, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}

/// One-off resets a provider hands out — Codex grants "Full reset (Weekly +
/// 5 hr)" and it is worth surfacing, because it changes what you do when a
/// weekly window is nearly gone.
struct ResetCredits: Decodable {
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

/// A provider's whole quota picture. Unknown keys (`credit_status`,
/// `spend_control`) are ignored by `Decodable`, so a tokscale release that adds
/// more of them does not break decoding.
///
/// Note what is NOT here: any notion of a provider being signed out. tokscale
/// reports the accounts it can actually read, so a provider you have never
/// signed into simply does not appear in the array — and that is the behaviour
/// to keep. A row that says "Not signed in" spends the scarcest thing this app
/// has, a line of notch, on telling you something you already know.
struct ProviderUsage: Decodable {
    let provider: String
    let plan: String?
    let email: String?
    let metrics: [UsageMetric]
    let resetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case provider, plan, email, metrics
        case resetCredits = "reset_credits"
    }
}

// MARK: - Token scan (`tokscale --json --group-by client,model`)

struct ScanEntry: Decodable {
    let client: String
    let model: String?
    let provider: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int?
    let messageCount: Int
    let cost: Double

    var totalTokens: Int { input + output + cacheRead + cacheWrite + (reasoning ?? 0) }
}

struct ScanReport: Decodable {
    let entries: [ScanEntry]
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheWrite: Int
    let totalMessages: Int
    let totalCost: Double

    var totalTokens: Int { totalInput + totalOutput + totalCacheRead + totalCacheWrite }

    /// Cost per client, largest first — what the expanded panel lists.
    var byClient: [(client: String, cost: Double, tokens: Int)] {
        var costs: [String: (Double, Int)] = [:]
        for entry in entries {
            let current = costs[entry.client] ?? (0, 0)
            costs[entry.client] = (current.0 + entry.cost, current.1 + entry.totalTokens)
        }
        return costs
            .map { (client: $0.key, cost: $0.value.0, tokens: $0.value.1) }
            .sorted { $0.cost > $1.cost }
    }

    static let empty = ScanReport(
        entries: [], totalInput: 0, totalOutput: 0, totalCacheRead: 0,
        totalCacheWrite: 0, totalMessages: 0, totalCost: 0
    )
}

// MARK: - Activity (`tokscale graph --json`)

/// One day on the contribution grid.
///
/// `intensity` comes from tokscale already bucketed 0…4 — deliberately not
/// re-derived here. Whatever thresholds it uses, using them is what keeps this
/// grid agreeing with every other tool reading the same data.
struct ContributionDay: Decodable, Hashable, Identifiable {
    struct Totals: Decodable, Hashable {
        let tokens: Int
        let cost: Double
        let messages: Int
    }

    let date: String
    let totals: Totals
    let intensity: Int

    var id: String { date }

    var day: Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)
    }
}

struct GraphReport: Decodable {
    struct Summary: Decodable {
        let totalTokens: Int
        let totalCost: Double
        let activeDays: Int
    }
    let summary: Summary
    let contributions: [ContributionDay]

    static let empty = GraphReport(
        summary: Summary(totalTokens: 0, totalCost: 0, activeDays: 0), contributions: [])
}

// MARK: - Sessions by project (`--group-by workspace,model`)

struct ProjectEntry: Decodable {
    let client: String
    let workspaceKey: String?
    let workspaceLabel: String?
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int?
    let messageCount: Int
    let cost: Double

    var totalTokens: Int { input + output + cacheRead + cacheWrite + (reasoning ?? 0) }
}

struct ProjectReport: Decodable {
    let entries: [ProjectEntry]
    static let empty = ProjectReport(entries: [])
}

/// One model, inside one agent, inside one project.
struct ProjectModelShare: Hashable, Identifiable {
    let model: String
    let tokens: Int
    let cost: Double

    var id: String { model }

    /// `claude-opus-5` reads as `opus-5`: the agent's own mark is on the line
    /// above, so repeating the vendor in the model name spends width on
    /// something already answered.
    var short: String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}

/// What one agent spent in one project.
struct ProjectAgentShare: Hashable, Identifiable {
    let client: String
    let tokens: Int
    let cost: Double
    let messages: Int
    /// Every model this agent used here, heaviest first. Never empty.
    let models: [ProjectModelShare]

    var id: String { client }
    var brand: Brand { Brand.match(client) }
}

/// What the tokens in a project actually were.
///
/// The figure that made this worth carrying: on a working machine **cache
/// reads are around 98% of every project's tokens**. A row that prints only
/// "189.5M" hides the one fact that explains the bill — that almost none of it
/// was written, it was read back. tokscale has returned this split all along;
/// the panel was discarding it at the fold.
struct TokenMix: Hashable {
    var input = 0
    var output = 0
    var reasoning = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + reasoning + cacheWrite + cacheRead }

    /// The share of this project's tokens that came back from cache, which is
    /// the one number from the split worth stating on its own.
    var cachedShare: Double {
        total > 0 ? Double(cacheRead) / Double(total) : 0
    }
}

/// One row of the Projects page: a project, folded across every agent and every
/// model that touched it.
struct ProjectUsage: Identifiable, Hashable {
    let name: String
    /// The canonical path this project folded under. The same key `WorkDay`
    /// files desk time by, which is what lets the page divide one into the
    /// other.
    let key: String
    /// Every agent that worked here, heaviest first. Never empty.
    let agents: [ProjectAgentShare]
    /// The model that spent the most in this project — the one worth naming.
    let model: String
    let tokens: Int
    let cost: Double
    let messages: Int
    /// What those tokens were: input, output, reasoning, cache.
    let mix: TokenMix

    var id: String { name }
    /// The agent that did most of the work, for anything that can only show one.
    var brand: Brand { agents.first?.brand ?? .generic }

    /// Each agent's share of this project's tokens, in the same order.
    var shares: [Double] {
        guard tokens > 0 else { return agents.map { _ in 0 } }
        return agents.map { Double($0.tokens) / Double(tokens) }
    }

    /// How many distinct models ran here, across every agent.
    var modelCount: Int { agents.reduce(0) { $0 + $1.models.count } }

    /// Folds a scan grouped by workspace and model into one row per project.
    ///
    /// A project shows once however many models it used, because the question
    /// the page answers is "what ate the quota" and the answer is a place, not
    /// a model. The dominant model rides along as a label.
    ///
    /// **Every agent that worked in the project is kept**, and that is the fix
    /// for a real bug: the bucket used to take its client from whichever entry
    /// happened to arrive first and never look again. A project worked on by
    /// Claude and Codex had both counted in its totals and only the first one
    /// named — so the row wore one agent's mark, reported the other's tokens
    /// inside its own, and read as though the second agent had not run at all.
    ///
    /// Nothing here knows which agents exist. The breakdown is built from the
    /// `client` strings in the scan, so a tool that tokscale learns about later
    /// appears on its own.
    /// The same directory, spelled two ways.
    ///
    /// When tokscale cannot resolve workspaces against the filesystem it
    /// reports each client's own key, and Claude's is the folder name it stores
    /// sessions under — every slash replaced by a dash:
    ///
    ///     claude   -Users-huypham-Desktop-projects-mon-dex
    ///     codex    /Users/huypham/Desktop/projects/mon-dex
    ///
    /// One project, two rows, each wearing one agent's mark and reporting a
    /// fraction of the work. Reported from a real screen.
    ///
    /// The dashes cannot simply be turned back into slashes: `mon-dex` has one
    /// of its own, and that is exactly the case this has to survive. So both
    /// forms are reduced instead — lowercased, split on either separator,
    /// joined back — and both become
    /// `users-huypham-desktop-projects-mon-dex`. Two directories that differ
    /// only in where a dash falls would collide, and one of those cannot exist:
    /// `mon/dex` is not a directory name.
    static func canonical(_ key: String) -> String {
        key.lowercased()
            .split(whereSeparator: { $0 == "/" || $0 == "-" })
            .joined(separator: "-")
    }

    /// tokscale appends the path to a label when two projects share a basename,
    /// and that suffix is worth keeping — it is the only thing telling them
    /// apart. It is dropped only when the entries folded into one bucket
    /// disagree about it, which is the case above: same project, two spellings,
    /// so the suffix is noise in both.
    static func name(from labels: Set<String>) -> String? {
        if labels.count == 1 { return labels.first }
        let stripped = Set(labels.map(base))
        if stripped.count == 1 { return stripped.first }
        return stripped.min { ($0.count, $0) < ($1.count, $1) }
    }

    private static func base(_ label: String) -> String {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return label }
        let inside = label[label.index(after: open)..<label.index(before: label.endIndex)]
        // Only a path is dropped. A project genuinely called "atlas (v2)" keeps
        // its name.
        guard inside.contains("/") || inside.hasPrefix("-") else { return label }
        return String(label[..<open]).trimmingCharacters(in: .whitespaces)
    }

    static func fold(_ report: ProjectReport) -> [ProjectUsage] {
        struct Agent {
            var tokens = 0
            var cost = 0.0
            var messages = 0
            var models: [String: (tokens: Int, cost: Double)] = [:]
        }
        struct Bucket {
            var tokens = 0
            var cost = 0.0
            var messages = 0
            var mix = TokenMix()
            var models: [String: Double] = [:]
            var agents: [String: Agent] = [:]
            /// Every spelling of this project's name that arrived.
            var labels: Set<String> = []
        }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for entry in report.entries {
            // Keyed by the path, not by the label: two agents can spell one
            // directory differently, and the label is what they disagree about.
            //
            // A session outside any repository still spent money, and hiding it
            // would make the page's total disagree with the header's.
            let key = entry.workspaceKey?.nilWhenEmpty.map(canonical)
                ?? entry.workspaceLabel?.nilWhenEmpty.map(canonical)
                ?? "elsewhere"
            if buckets[key] == nil { order.append(key) }
            var bucket = buckets[key] ?? Bucket()
            if let label = entry.workspaceLabel?.nilWhenEmpty { bucket.labels.insert(label) }
            bucket.tokens += entry.totalTokens
            bucket.cost += entry.cost
            bucket.messages += entry.messageCount
            bucket.mix.input += entry.input
            bucket.mix.output += entry.output
            bucket.mix.reasoning += entry.reasoning ?? 0
            bucket.mix.cacheWrite += entry.cacheWrite
            bucket.mix.cacheRead += entry.cacheRead
            if let model = entry.model {
                bucket.models[model, default: 0] += entry.cost
            }
            var agent = bucket.agents[entry.client] ?? Agent()
            agent.tokens += entry.totalTokens
            agent.cost += entry.cost
            agent.messages += entry.messageCount
            // An agent with no model named still worked here, and dropping the
            // line would leave its bar with nothing under it.
            let model = entry.model?.nilWhenEmpty ?? "unknown"
            let seen = agent.models[model] ?? (0, 0)
            agent.models[model] = (seen.tokens + entry.totalTokens, seen.cost + entry.cost)
            bucket.agents[entry.client] = agent
            buckets[key] = bucket
        }

        return order.compactMap { key -> ProjectUsage? in
            guard let b = buckets[key] else { return nil }
            let name = Self.name(from: b.labels)
                ?? key.split(separator: "-").last.map(String.init)
                ?? "elsewhere"
            let agents = b.agents
                .map { client, a in
                    ProjectAgentShare(
                        client: client, tokens: a.tokens, cost: a.cost, messages: a.messages,
                        models: a.models
                            .map { ProjectModelShare(model: $0.key, tokens: $0.value.tokens,
                                                     cost: $0.value.cost) }
                            .sorted { ($0.tokens, $0.model) > ($1.tokens, $1.model) })
                }
                // Tokens, not cost: an agent can do a great deal of work on a
                // plan that bills it at nothing, and it still worked here.
                .sorted { ($0.tokens, $0.client) > ($1.tokens, $1.client) }
            guard !agents.isEmpty else { return nil }
            return ProjectUsage(
                name: name, key: key, agents: agents,
                model: b.models.max { $0.value < $1.value }?.key ?? "—",
                tokens: b.tokens, cost: b.cost, messages: b.messages, mix: b.mix)
        }
        .sorted { $0.cost > $1.cost }
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

// MARK: - What the notch actually draws

/// A provider reduced to the one number the ring needs, with the rest kept for
/// the expanded panel.
struct ProviderSnapshot: Identifiable, Hashable, Codable {
    /// What the roster on disk carries. `trends` is deliberately absent: it is
    /// derived from the recorded samples, and a stale projection restored from
    /// a previous launch would be drawn as though it were current.
    enum CodingKeys: String, CodingKey {
        case provider, plan, email, metrics, freeResets, seenAt, isStale
    }

    let provider: String
    let plan: String?
    let email: String?
    let metrics: [UsageMetric]
    /// How many one-off resets are banked, when the provider grants them.
    let freeResets: Int
    /// When these numbers were last actually reported by the provider.
    let seenAt: Date
    /// True when the last fetch did not include this provider and what is drawn
    /// is the previous answer. See `UsageStore.merge`.
    let isStale: Bool

    var id: String { provider }

    /// Every window whose plan actually funds it. Copilot reports Chat and
    /// Completions as `0/0` on Individual; those are spent by definition and
    /// letting one win would peg the ring at empty for an untouched account.
    var meteredMetrics: [UsageMetric] { metrics.filter { !$0.hasNoAllowance } }

    /// Recent pace per window, keyed by label. Filled in by `UsageStore` from
    /// the recorded history; empty until a window has two readings inside its
    /// own lookback span.
    var trends: [String: QuotaTrend] = [:]

    /// The window worth worrying about.
    ///
    /// This used to be `max(by: usedPercent)` across every window, and that was
    /// wrong — not marginally, but in the way that produces a confident answer
    /// to a question that was never asked. A 7-day window at 84% left and a
    /// 5-hour at 89% left are not two points on one scale of urgency: they meter
    /// different amounts over different spans, and whichever number is larger
    /// says nothing about which one you will hit first.
    ///
    /// So the comparison is made on the only quantity that IS shared between
    /// windows — **wall-clock time until the allowance is gone**. Seconds are
    /// seconds whatever the window's length, and a window that survives to its
    /// own reset has no exhaustion time at all rather than a very large one, so
    /// it never enters the ordering.
    ///
    /// When nothing is on course to run out, nothing is urgent and the choice
    /// stops mattering — so it falls back to the fullest window, which is what
    /// a reader expects to see and costs nothing when no window is at risk.
    var headline: UsageMetric? {
        let real = meteredMetrics.isEmpty ? metrics : meteredMetrics

        let atRisk = real.compactMap { metric -> (UsageMetric, TimeInterval)? in
            guard let seconds = trends[metric.label]?.timeToExhaustion else { return nil }
            return (metric, seconds)
        }
        if let soonest = atRisk.min(by: { $0.1 < $1.1 }) { return soonest.0 }

        return real.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    /// Set when the headline was chosen because that window is projected to run
    /// out before it resets, rather than merely being the fullest one. The two
    /// deserve different words on screen.
    var headlineRunsOutEarly: Bool {
        guard let label = headline?.label else { return false }
        return trends[label]?.runsOutEarly ?? false
    }

    var fraction: Double { headline?.fraction ?? 0 }
    /// What the strip and the ring caption print — left, like everywhere else.
    var remainingFraction: Double { headline?.remainingFraction ?? 1 }
    var percentText: String { "\(Int((remainingFraction * 100).rounded()))%" }

    var brand: Brand { Brand.match(provider) }

    /// The short window — the one that decides whether you can keep working
    /// *right now*. Claude calls it "Session", Codex "5h"; a provider without
    /// one falls back to the tightest window it does meter.
    ///
    /// This is what the strip shows, and it is a different choice from
    /// `headline`: the headline is the window closest to empty, which for a
    /// heavy week is the weekly one. Beside the notch, at a glance, the
    /// question is narrower — "can I send the next prompt" — and that is a
    /// question about the session.
    var sessionMetric: UsageMetric? {
        let metered = meteredMetrics
        let short = metered.first { metric in
            let label = metric.label.lowercased()
            if label.contains("session") || label.contains("hour") { return true }
            // "5h", "3h" — a bare hour count.
            return label.hasSuffix("h") && Int(label.dropLast()) != nil
        }
        return short ?? headline
    }

    var sessionLeftFraction: Double { sessionMetric?.remainingFraction ?? 1 }
    var sessionLeftText: String { "\(Int((sessionLeftFraction * 100).rounded()))%" }
}
