import SwiftUI

/// The fourth tab.
///
/// Everything above the first rule is a total, and a total could live on
/// Overview — it does, in `TimeBand`. This page exists for the one thing a
/// total cannot say: the shape of a day.
struct TimePage: View {
    let pointer: PointerTracker

    @ObservedObject private var monitor = PresenceMonitor.shared
    @ObservedObject private var history = WorkHistory.shared

    private var rhythm: [Double] { WorkHistory.rhythm(history.days) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section(title: "", isFirst: true) {
                today
            }
            Section(title: "When you work", aside: "last \(WorkHistory.windowDays) days") {
                RhythmChart(rhythm: rhythm, pointer: pointer)
            }
            Section(title: "") {
                facts
            }
        }
    }

    private var today: some View {
        let clock = monitor.clock
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(clock.desk.clockText)
                    .font(Typeface.number(33))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primaryText)
                Text("at the desk today")
                    .font(Typeface.label(12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 12)
                Text("sitting")
                    .font(Typeface.label(11.5, weight: .medium))
                    .foregroundStyle(Palette.faintText)
                Text(clock.sitting(at: monitor.now).clockText)
                    .font(Typeface.number(12))
                    .monospacedDigit()
                    .foregroundStyle(StretchTone.of(clock.sitting(at: monitor.now)).color)
            }
            StretchGauge(stretch: clock.sitting(at: monitor.now), caption: "rest at 90m")
        }
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: 0) {
            let window = history.days.suffix(WorkHistory.windowDays)
            fact("\(WorkHistory.activeDays(history.days))",
                 suffix: "/\(max(window.count, 1))",
                 caption: "days with work\non them",
                 hot: WorkHistory.activeDays(history.days) == window.count && !window.isEmpty)
            fact("\(WorkHistory.daysOverThreshold(history.days))",
                 caption: "days with a stretch\npast 90 minutes")
            let longest = WorkHistory.longestStretch(history.days)?.longestStretch
            fact(longest?.figureAndUnit.figure ?? "—",
                 suffix: longest?.figureAndUnit.unit,
                 caption: "longest unbroken\nstretch")
            let median = WorkHistory.medianDesk(history.days)
            fact(median.figureAndUnit.figure, suffix: median.figureAndUnit.unit,
                 caption: "median day\nat the desk")
        }
    }

    private func fact(_ value: String, suffix: String? = nil,
                      caption: String, hot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(Typeface.number(24))
                    .monospacedDigit()
                    .foregroundStyle(hot ? Palette.critical : Palette.primaryText)
                if let suffix {
                    Text(suffix)
                        .font(Typeface.number(15))
                        .monospacedDigit()
                        .foregroundStyle(Palette.faintText)
                }
            }
            Text(caption)
                .font(Typeface.label(10.5, weight: .medium))
                .foregroundStyle(Palette.faintText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Hours worked against the clock hour they happened in.
///
/// The night band is marked twice — a shifted bar colour and a rule beneath it
/// — because a band told apart by hue alone is a band some readers cannot see.
struct RhythmChart: View {
    let rhythm: [Double]
    let pointer: PointerTracker

    /// Matched to the `HStack` the bars are laid out in, so the hit test and
    /// the drawing cannot disagree about where a column is.
    static let gap: CGFloat = 2
    static let height: CGFloat = 92

    private var peak: Double { max(rhythm.max() ?? 0, 1) }
    private var peakHour: Int? { WorkHistory.peakHour(rhythm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(0..<24, id: \.self) { hour in
                    bar(hour)
                }
            }
            .frame(height: Self.height)
            // Layered over the bars rather than attached to them: a bar that
            // grew or gained a ring would change width inside the flexible
            // columns and shove the whole day sideways under the pointer —
            // the same reason the activity grid draws its ring in an overlay.
            .overlay { RhythmTooltip(rhythm: rhythm, pointer: pointer) }

            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(WorkHistory.isNight(hour) ? Palette.critical.opacity(0.55) : .clear)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? String(format: "%02d", hour) : "")
                        .font(Typeface.number(8.5))
                        .foregroundStyle(Palette.faintText)
                        .frame(maxWidth: .infinity)
                }
            }
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private func bar(_ hour: Int) -> some View {
        // A floor of one point, so an hour with nothing in it still reads as a
        // column that exists and measured zero rather than as a gap in the
        // chart.
        let share = rhythm[hour] / peak
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(colour(hour))
            .frame(height: max(1, Self.height * share))
            .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private func colour(_ hour: Int) -> Color {
        if hour == peakHour { return Palette.critical }
        if WorkHistory.isNight(hour) { return Palette.night }
        return Palette.control
    }

    private var legend: some View {
        HStack(spacing: 16) {
            if let peakHour {
                Text("peak \(String(format: "%02d", peakHour)):00")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.night)
                    .frame(width: 8, height: 8)
                Text("22:00–06:00")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                Text("\(Int((WorkHistory.nightShare(rhythm) * 100).rounded()))%")
                    .font(Typeface.number(10.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primaryText)
                Text("of everything")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var summary: String {
        guard let peakHour else { return "No work recorded yet." }
        return "Hours worked by clock hour. Peak at \(peakHour):00. "
            + "\(Int((WorkHistory.nightShare(rhythm) * 100).rounded())) percent between 22:00 and 06:00."
    }
}


/// Which hour the pointer is over.
struct RhythmHit {
    let hour: Int
    /// In the chart's own coordinates.
    let rect: CGRect

    /// `point` and `bounds` share a coordinate space. Returns nil outside the
    /// chart and inside a gap between columns, so a card never names an hour
    /// the pointer is not on.
    static func at(_ point: CGPoint, in bounds: CGRect, height: CGFloat) -> RhythmHit? {
        guard bounds.width > 0 else { return nil }
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        guard local.x >= 0, local.x < bounds.width, local.y >= 0, local.y <= height else { return nil }

        let gaps = CGFloat(23) * RhythmChart.gap
        let width = (bounds.width - gaps) / 24
        guard width > 0 else { return nil }
        let pitch = width + RhythmChart.gap

        let hour = Int(local.x / pitch)
        guard hour < 24 else { return nil }
        let rect = CGRect(x: CGFloat(hour) * pitch, y: 0, width: width, height: height)
        guard local.x <= rect.maxX else { return nil }
        return RhythmHit(hour: hour, rect: rect)
    }
}

/// The card that names the hour under the pointer.
///
/// Twenty-four bars two points apart is a shape: you can see that the evening
/// is heavy and that 04:00 is empty, and you cannot read a figure off it. The
/// card is what turns the shape back into hours — the same job it does on the
/// activity grid, and the reason both are worth hovering.
private struct RhythmTooltip: View {
    let rhythm: [Double]
    @ObservedObject var pointer: PointerTracker

    /// Seeded near the card's real size so the first frame after a hover is
    /// already in place rather than sliding into it.
    @State private var cardSize = CGSize(width: 108, height: 34)

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            if let hit = RhythmHit.at(pointer.location ?? .init(x: -1, y: -1),
                                      in: bounds, height: RhythmChart.height) {
                Rectangle()
                    .fill(Palette.primaryText.opacity(0.07))
                    .frame(width: hit.rect.width + 2, height: RhythmChart.height)
                    .position(x: hit.rect.midX, y: RhythmChart.height / 2)

                Card(hour: hit.hour, seconds: rhythm[hit.hour])
                    .measureSize { size in
                        Task { @MainActor in if size != .zero, size != cardSize { cardSize = size } }
                    }
                    .position(
                        // Held inside the chart, so an hour at either end does
                        // not put half the card off the panel.
                        x: min(max(hit.rect.midX, cardSize.width / 2),
                               max(bounds.width - cardSize.width / 2, cardSize.width / 2)),
                        y: max(cardSize.height / 2,
                               RhythmChart.height - RhythmChart.height * (rhythm[hit.hour] / max(rhythm.max() ?? 1, 1))
                                 - 6 - cardSize.height / 2))
            }
        }
        .allowsHitTesting(false)
    }

    private struct Card: View {
        let hour: Int
        let seconds: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(seconds > 0 ? seconds.clockText : "none")
                        .font(Typeface.number(12))
                        .monospacedDigit()
                        .foregroundStyle(seconds > 0 ? Palette.primaryText : Palette.faintText)
                    if seconds > 0 {
                        Text("at the desk")
                            .font(Typeface.label(9.5))
                            .foregroundStyle(Palette.faintText)
                    }
                }
                HStack(spacing: 4) {
                    Text(String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24))
                        .font(Typeface.number(9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.faintText)
                    if WorkHistory.isNight(hour) {
                        Text("night")
                            .font(Typeface.label(9, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.5)
                            .foregroundStyle(Palette.critical.opacity(0.8))
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                shape.fill(Palette.surface)
                    .overlay { shape.fill(Palette.activeFill) }
                    .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.5), radius: 7, y: 3)
            }
        }
    }
}
