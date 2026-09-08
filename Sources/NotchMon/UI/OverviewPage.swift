import SwiftUI

/// Opens on today's total, then a dial per agent, then a year of activity.
struct OverviewPage: View {
    @ObservedObject var store: UsageStore
    let pointer: PointerTracker

    /// Whichever agent burned the most today. The hero takes its colour, so the
    /// colour is a fact rather than a flourish.
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
                ActivityGrid(days: store.activity, brand: leader, pointer: pointer)
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

    /// A grid rather than an HStack so the rings land on the same verticals
    /// however long the names are.
    private var dials: some View {
        let agents = store.visibleProviders
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading),
                           count: max(min(agents.count, 3), 1)),
            alignment: .leading, spacing: 12
        ) {
            ForEach(agents) { AgentDial(snapshot: $0) }
        }
        .padding(.top, 15)
    }
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
