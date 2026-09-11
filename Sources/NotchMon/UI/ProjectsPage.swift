import SwiftUI

/// Today's spend: the projects ranked on the left, one of them explained on
/// the right.
///
/// The question Overview cannot answer is **what ate the quota**, and the
/// answer has two halves that want different amounts of room. Which project
/// is a ranking — short rows, six of them, compared by looking. Why that
/// project is a breakdown — every agent that worked there, every model each
/// one ran, and what the tokens actually were — and that does not fit on a
/// row.
///
/// So the panel is split, the way Settings already splits it: this is a wide,
/// short surface, and a single column either truncates the detail or shows two
/// projects. The left column ranks; the right column explains.
struct ProjectsPage: View {
    @ObservedObject var store: UsageStore

    /// The selection is held by **name**, not by index. A refresh can reorder
    /// the list under the pointer, and an index would quietly start describing
    /// a different project than the one that is highlighted.
    @State private var picked: String?

    private var projects: [ProjectUsage] { store.projects }
    private var maxCost: Double { projects.first?.cost ?? 1 }

    /// Falls back to the heaviest project, which is also what opens by default:
    /// the page is a ranking, so the top of it is the thing to explain first.
    private var selected: ProjectUsage? {
        projects.first { $0.name == picked } ?? projects.first
    }

    var body: some View {
        Section(title: "Today by project", aside: aside, isFirst: true) {
            if let project = selected {
                HStack(alignment: .top, spacing: ProjectMetrics.paneGap) {
                    list(selected: project)
                        .frame(width: ProjectMetrics.listWidth, alignment: .leading)

                    ProjectDetail(project: project)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, ProjectMetrics.paneGap)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.hairline).frame(width: 1)
                        }
                }
            } else {
                empty
            }
        }
    }

    private var aside: String {
        projects.isEmpty ? "—" : "\(projects.count) · \(store.today.totalCost.money)"
    }

    private func list(selected: ProjectUsage) -> some View {
        VStack(spacing: 1) {
            ForEach(projects.prefix(6)) { project in
                ProjectRow(
                    project: project,
                    fill: maxCost > 0 ? project.cost / maxCost : 0,
                    isSelected: project.id == selected.id,
                    select: { picked = project.name })
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing recorded today")
                .font(Typeface.label(12, weight: .semibold))
                .foregroundStyle(Palette.primaryText)
            Text("Projects appear here as soon as an agent runs in one")
                .font(Typeface.label(10))
                .foregroundStyle(Palette.faintText)
        }
        .padding(.vertical, 14)
    }
}

/// Page-local sizes. Not in `Metrics`: nothing outside this file lays out
/// against them, and the shared table is for numbers the app agrees on.
private enum ProjectMetrics {
    /// The ranking column. Wide enough for a repository name at 11.5 points
    /// with its marks and its cost either side of it.
    static let listWidth: CGFloat = 208
    /// Half the space between the two columns; the rule sits in the middle of
    /// the pair, so this is applied twice.
    static let paneGap: CGFloat = 18
    /// The agent's name in the detail pane, and the indent its models line up
    /// under.
    static let agentName: CGFloat = 86
}

// MARK: - The ranking

private struct ProjectRow: View {
    let project: ProjectUsage
    /// This project's cost as a share of the heaviest one's.
    let fill: Double
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    AgentMarks(agents: project.agents, size: 10)
                    Text(project.name)
                        .font(Typeface.label(11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Palette.primaryText : Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(project.cost.money)
                        .font(Typeface.number(10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Palette.primaryText : Palette.faintText)
                }
                AgentRail(project: project, fill: fill)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Palette.activeFill : (hovering ? Palette.hover : .clear))
            }
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Names the agents, because the marks are the only place the split shows
    /// on this row and a mark has no text.
    private var label: String {
        let who = project.agents.map(\.client).joined(separator: " and ")
        return "\(project.name), \(who), \(project.cost.compactMoney)"
    }
}

// MARK: - The explanation

private struct ProjectDetail: View {
    let project: ProjectUsage

    @ObservedObject private var history = WorkHistory.shared

    /// Hours at the desk on this project today.
    ///
    /// The one figure in this app that neither half could produce alone: the
    /// scan knows what was spent and the presence clock knows who was there,
    /// and only together do they say what an hour of work costs.
    private var desk: TimeInterval { history.today()?.projects[project.key] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            agents.padding(.top, 14)
            mix.padding(.top, 14)
            footer.padding(.top, 13)
        }
    }

    /// The figure the page exists for, in the leading agent's colour.
    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(project.tokens.compactTokens)
                .font(Typeface.number(27))
                .monospacedDigit()
                .foregroundStyle(project.brand.color)
            Text("tokens · \(project.name)")
                .font(Typeface.label(10.5))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(project.cost.money)
                .font(Typeface.number(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), \(project.tokens.grouped) tokens, \(project.cost.compactMoney)")
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Agents").padding(.bottom, 7)
            ForEach(Array(zip(project.agents, project.shares)), id: \.0.id) { agent, share in
                AgentLine(agent: agent, share: share)
            }
        }
    }

    private var mix: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Token mix").padding(.bottom, 7)
            MixBar(mix: project.mix)
            MixKey(mix: project.mix).padding(.top, 7)
        }
    }

    private var footer: some View {
        Text(counts)
            .font(Typeface.label(10))
            .foregroundStyle(Palette.faintText)
    }

    private var counts: String {
        let agents = project.agents.count
        let models = project.modelCount
        var line = "\(project.messages) messages · \(agents) agent\(agents == 1 ? "" : "s")"
            + " · \(models) model\(models == 1 ? "" : "s")"
        // Here rather than beside the figure above it. The hero row is tokens,
        // name and cost, and a fourth item wrapped the number onto two lines
        // and truncated the name — the derived facts belong together anyway.
        if desk > 0 { line += " · \(desk.clockText) at the desk" }
        // The rate only past a quarter of an hour. Ten minutes turns any spend
        // into a number that sounds like a salary and means nothing.
        if desk >= 15 * 60 {
            line += " · \((project.cost / (desk / 3600)).money) an hour"
        }
        return line
    }
}

/// One agent inside the selected project: what it did, on a bar, with the
/// models it ran named underneath.
private struct AgentLine: View {
    let agent: ProjectAgentShare
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                HStack(spacing: 6) {
                    BrandMark(brand: agent.brand, size: 11)
                    Text(agent.client)
                        .font(Typeface.label(11))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                }
                .frame(width: ProjectMetrics.agentName, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule().fill(agent.brand.color)
                            .frame(width: max(proxy.size.width * share, 2))
                    }
                }
                .frame(height: 4)

                Text(agent.tokens.compactTokens)
                    .font(Typeface.number(11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 62, alignment: .trailing)

                Text(agent.cost.money)
                    .font(Typeface.number(11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primaryText)
                    .frame(width: 54, alignment: .trailing)
            }
            .frame(height: 18)

            // Two lines, not one. An agent that ran three models put the
            // third one past the edge as "opus-…", which names a model badly
            // enough to be worse than not naming it — and this line is the
            // only place on the panel a model appears at all.
            Text(models)
                .font(Typeface.number(9.5, weight: .regular))
                .foregroundStyle(Palette.faintText)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ProjectMetrics.agentName + 9)
                .padding(.bottom, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.client), \(agent.tokens.grouped) tokens, "
            + "\(agent.cost.compactMoney), \(agent.messages) messages, \(models)")
    }

    /// One model: name it. Several: name each with what it did, because this
    /// line is the only place that split appears. Printing the figure beside a
    /// single model would be printing the same number twice on one row.
    private var models: String {
        guard agent.models.count > 1 else { return agent.models.first?.short ?? "—" }
        return agent.models
            .map { "\($0.short) \($0.tokens.compactTokens)" }
            .joined(separator: "  ·  ")
    }
}

// MARK: - Bars

/// One project's tokens, split by the agents that spent them, on a track whose
/// filled length is that project's share of the heaviest row.
///
/// Rank and split in one three-point object: length answers "how much of the
/// day", the segments answer "who".
///
/// The cut between segments is not decoration. Codex's mark is very nearly
/// white, and a white segment butted straight against the track reads as the
/// *unfilled* part of the bar — the same agent going missing that this page
/// was rebuilt to fix, in a different disguise. The cuts show the panel's own
/// surface, so they read as divisions rather than as the end of the fill.
private struct AgentRail: View {
    let project: ProjectUsage
    var fill: Double = 1
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width * fill, 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surface)
                    HStack(spacing: 1.5) {
                        ForEach(Array(zip(project.agents, project.shares)), id: \.0.id) { agent, part in
                            Rectangle().fill(agent.brand.color)
                                .frame(width: max(width * part - 1.5, 0.5))
                        }
                    }
                }
                .frame(width: width, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// What the tokens were, in neutrals.
///
/// Neutral on purpose: the panel's one colour rule is that a saturated hue
/// names a vendor, and a cache read is not one.
private struct MixBar: View {
    let mix: TokenMix
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(mixBands(mix)) { band in
                    Rectangle()
                        .fill(Palette.primaryText.opacity(band.tone))
                        .frame(width: max(proxy.size.width * band.share(of: mix) - 1, 0.5))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .background { Capsule().fill(Palette.track) }
        .accessibilityHidden(true)
    }
}

/// The bar's legend, which is where its figures live — at 96% cache read the
/// bar alone says "one thing" and not which thing or how much.
private struct MixKey: View {
    let mix: TokenMix

    var body: some View {
        let bands = mixBands(mix)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: bands.count, by: 3)), id: \.self) { start in
                HStack(spacing: 13) {
                    ForEach(bands[start..<min(start + 3, bands.count)]) { band in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Palette.primaryText.opacity(band.tone))
                                .frame(width: 7, height: 7)
                            Text(band.label)
                                .font(Typeface.label(9.5))
                                .foregroundStyle(Palette.faintText)
                            Text(band.value.compactTokens)
                                .font(Typeface.number(10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// One band of the token mix: what it is called, how heavy it draws, and how
/// much of it there was.
private struct MixBand: Identifiable {
    let label: String
    let tone: Double
    let value: Int

    var id: String { label }

    func share(of mix: TokenMix) -> Double {
        mix.total > 0 ? Double(value) / Double(mix.total) : 0
    }
}

/// Dearest first, so the bar reads left to right as "what you paid full price
/// for", then "what came back from cache".
///
/// Nothing goes lighter than cache read's weight: below about a quarter it is
/// indistinguishable from the track, and since cache read is routinely 96% of
/// a project, the whole bar would then read as empty. Empty bands are dropped
/// — a zero-width segment is not information.
private func mixBands(_ mix: TokenMix) -> [MixBand] {
    [MixBand(label: "input", tone: 0.92, value: mix.input),
     MixBand(label: "output", tone: 0.70, value: mix.output),
     MixBand(label: "reasoning", tone: 0.54, value: mix.reasoning),
     MixBand(label: "cache write", tone: 0.41, value: mix.cacheWrite),
     MixBand(label: "cache read", tone: 0.27, value: mix.cacheRead)]
        .filter { $0.value > 0 }
}

/// Every agent that worked in a project, up to three. Three because a fourth
/// mark starts pushing the name into an ellipsis, and by then the rail below
/// is carrying the split anyway.
private struct AgentMarks: View {
    let agents: [ProjectAgentShare]
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(agents.prefix(3)) { agent in
                BrandMark(brand: agent.brand, size: size)
            }
        }
    }
}
