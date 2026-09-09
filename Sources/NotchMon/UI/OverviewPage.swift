import SwiftUI

/// Opens on today's total, then a dial per agent, then a year of activity.
struct OverviewPage: View {
    @ObservedObject var store: UsageStore
    let pointer: PointerTracker

    /// Whichever agent burned the most today. The hero figure takes its colour,
    /// so the colour is a fact rather than a flourish.
    ///
    /// Not the activity grid, though: that is a year of every agent summed, and
    /// one vendor's hue over all of it would name the wrong subject.
    private var leader: Brand {
        guard let top = store.today.byClient.first else { return .generic }
        return Brand.match(top.client)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section(title: "", isFirst: true) {
                hero
                dials
            }
            Section(title: "Activity", aside: activityAside) {
                ActivityGrid(days: store.activity, pointer: pointer)
            }
        }
    }

    private var activityAside: String {
        store.activeDays > 0 ? "\(store.activeDays) active days" : "—"
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(store.today.totalTokens.compactTokens)
                .font(Typeface.number(34, weight: .semibold))
                .kerning(-1)
                .monospacedDigit()
                .foregroundStyle(leader.color)
            Text("tokens today")
                .font(Typeface.label(10.5))
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 8)
            Text(store.today.totalCost.money)
                .font(Typeface.number(13))
                .monospacedDigit()
                .foregroundStyle(Palette.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.today.totalTokens.grouped) tokens today, \(store.today.totalCost.money)")
    }

    /// The ones that matter, in full; everything else as an inventory.
    ///
    /// The dial section holds two agents today and was never asked to hold ten.
    /// It does not fail on width — three columns of 188 points still carry the
    /// second line — it fails on **height**: ten rich dials is four rows, and
    /// four rows adds about 220 points to a panel already 350 tall and hanging
    /// off a notch.
    ///
    /// So the panel spends its height on the agents that are close to running
    /// out and lists the rest. A chip is a mark, a name and a figure — enough
    /// to say "installed, and fine" — and its reset rides in the tooltip rather
    /// than taking a line it does not deserve.
    @ViewBuilder
    private var dials: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading),
                           count: max(headline.count, 1)),
            alignment: .leading, spacing: 12
        ) {
            ForEach(headline) { AgentDial(snapshot: $0) }
        }
        .padding(.top, 15)

        if !roster.isEmpty {
            AgentRoster(agents: roster).padding(.top, 13)
        }
    }

    private var split: OverviewRoster.Split { OverviewRoster.split(store.visibleProviders) }
    private var headline: [ProviderSnapshot] { split.headline }
    private var roster: [ProviderSnapshot] { split.roster }
}

/// One agent: a ring for the window that decides right now, and underneath it
/// the longer window that decides the week.
///
/// A ring can only show one window, and showing the session alone hid the limit
/// that actually bites on a heavy week — 89% and 84% only mean something next
/// to each other.
struct AgentDial: View {
    let snapshot: ProviderSnapshot

    private var primary: UsageMetric? { snapshot.sessionMetric }
    private var secondary: UsageMetric? {
        snapshot.meteredMetrics.first { $0.label != primary?.label }
    }

    private var spent: Double { primary?.fraction ?? 0 }
    private var isCritical: Bool { spent >= Palette.criticalSpent }
    /// The pace line takes precedence over the reset countdown: once a window is
    /// on course to run dry, its reset is no longer the next thing that happens
    /// to you.
    private var runsOut: String? {
        guard let label = primary?.label,
              let seconds = snapshot.trends[label]?.timeToExhaustion
        else { return nil }
        return "out in " + Self.short(seconds)
    }

    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }

    var body: some View {
        HStack(spacing: 9) {
            UsageRing(
                remaining: primary?.remainingFraction ?? 1,
                tone: Palette.tone(snapshot.brand, spent: spent),
                size: 32
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(primary?.countText ?? "\(Int(((primary?.remainingFraction ?? 1) * 100).rounded()))%")
                        .font(Typeface.number(12))
                        .monospacedDigit()
                        .foregroundStyle(isCritical ? Palette.critical : Palette.primaryText)
                    Text("left")
                        .font(Typeface.label(9.5))
                        .foregroundStyle(Palette.faintText)
                }
                Text(subtitle)
                    .font(Typeface.label(10))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                if let second = secondLine {
                    Text(second)
                        .font(Typeface.number(9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(runsOut != nil ? Palette.critical : Palette.faintText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var subtitle: String {
        var parts = [snapshot.provider.lowercased()]
        if let label = primary?.label { parts.append(label) }
        if let reset = primary?.resetDate?.untilNow { parts.append(reset) }
        return parts.joined(separator: " · ")
    }

    private var secondLine: String? {
        if let runsOut { return runsOut }
        guard let second = secondary else { return nil }
        let left = second.countText ?? "\(Int((second.remainingFraction * 100).rounded()))%"
        guard let reset = second.resetDate?.untilNow else { return "\(second.label) \(left)" }
        return "\(second.label) \(left) · \(reset)"
    }

    private var accessibilityText: String {
        var text = "\(snapshot.provider), \(primary?.label ?? "quota") "
        text += "\(Int(((primary?.remainingFraction ?? 1) * 100).rounded())) percent left"
        if let runsOut { text += ", \(runsOut)" }
        return text
    }
}


/// Which agents get a dial and which get a chip.
///
/// Split out of the view so the rule can be tested: it is the whole of the
/// layout decision, and the layout it decides only misbehaves at agent counts
/// no real desk has.
enum OverviewRoster {
    struct Split: Equatable {
        var headline: [ProviderSnapshot]
        var roster: [ProviderSnapshot]
    }

    /// One full row of dials. Three rather than two, so the counts that
    /// actually occur — one, two, three agents — are unchanged from what
    /// shipped, and the roster appears only when there is something to put in
    /// it.
    static let headlineCount = 3

    /// Ranked by what is left, so the agent about to run out leads.
    ///
    /// The ordering is what the layout is built on rather than a preference:
    /// the point of a headline is that it is *chosen*, and choosing it by
    /// anything other than urgency would make the roster below it arbitrary.
    /// Ties break on name so the order is stable between refreshes — two agents
    /// both sitting at 100% must not trade places every time the quota poll
    /// lands.
    static func split(_ agents: [ProviderSnapshot]) -> Split {
        let ranked = agents.sorted {
            ($0.sessionLeftFraction, $0.provider) < ($1.sessionLeftFraction, $1.provider)
        }
        return Split(headline: Array(ranked.prefix(headlineCount)),
                     roster: Array(ranked.dropFirst(headlineCount)))
    }
}

/// Every other agent: installed, reporting, and not the problem.
///
/// A chip carries the three things that answer "should I care" — whose it is,
/// what it is called, and how much is left — and nothing else. The reset is in
/// the tooltip: it is the second question, and a second line across seven chips
/// would cost more height than the dials this section exists to avoid.
struct AgentRoster: View {
    let agents: [ProviderSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 7, lineSpacing: 6) {
                ForEach(agents) { Chip(snapshot: $0) }
            }
            Text(summary)
                .font(Typeface.label(9.5))
                .foregroundStyle(Palette.faintText)
        }
    }

    /// What the chips cannot say between them: how many, and when the first of
    /// them comes back.
    private var summary: String {
        var text = "\(agents.count) more"
        if let soonest = agents
            .compactMap({ $0.sessionMetric?.resetDate })
            .min()?.untilNow {
            text += " · nearest reset \(soonest)"
        }
        return text
    }

    private struct Chip: View {
        let snapshot: ProviderSnapshot

        private var left: Double { snapshot.sessionLeftFraction }
        private var isCritical: Bool { 1 - left >= Palette.criticalSpent }

        var body: some View {
            HStack(spacing: 5) {
                BrandMark(brand: snapshot.brand, size: 11,
                          tint: isCritical ? Palette.critical : nil)
                Text(snapshot.provider.lowercased())
                    .font(Typeface.label(10))
                    .foregroundStyle(Palette.faintText)
                    .lineLimit(1)
                Text(snapshot.sessionLeftText)
                    .font(Typeface.number(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isCritical ? Palette.critical : Palette.secondaryText)
            }
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.hover)
                    // Only a spent chip takes an outline. Seven bordered boxes
                    // in a row is a row of buttons; one is a thing to look at.
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isCritical ? Palette.critical.opacity(0.55) : .clear,
                                          lineWidth: 1)
                    }
            }
            .help(tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltip)
        }

        private var tooltip: String {
            var text = "\(snapshot.provider), \(snapshot.sessionLeftText) left"
            if let reset = snapshot.sessionMetric?.resetDate?.untilNow {
                text += ", resets in \(reset)"
            }
            return text
        }
    }
}

/// Chips laid left to right, wrapping when the row runs out.
///
/// Hand-written because there is no wrapping stack before macOS 15 and this app
/// targets 14 — and because a `LazyVGrid` cannot do it: a grid gives every cell
/// the same width, and these are the width of their own names.
struct FlowRow: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = wrap(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in wrap(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width = next
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
