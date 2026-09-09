import SwiftUI

/// The fourth tab.
///
/// Everything above the first rule is a total, and a total could live on
/// Overview — it does, in `TimeBand`. This page exists for the one thing a
/// total cannot say: the shape of a day.
struct TimePage: View {
    @ObservedObject private var monitor = PresenceMonitor.shared
    @ObservedObject private var history = WorkHistory.shared

    private var rhythm: [Double] { WorkHistory.rhythm(history.days) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section(title: "", isFirst: true) {
                today
            }
            Section(title: "When you work", aside: "last \(WorkHistory.windowDays) days") {
                RhythmChart(rhythm: rhythm)
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
            DeskSplit(desk: clock.desk, coding: clock.coding)
            HStack(spacing: 18) {
                key(Palette.control, "coding", clock.coding)
                key(Palette.track, "everything else", max(0, clock.desk - clock.coding))
                Spacer(minLength: 0)
            }
            StretchGauge(stretch: clock.sitting(at: monitor.now), caption: "rest at 90m")
        }
    }

    private func key(_ colour: Color, _ label: String, _ value: TimeInterval) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colour).frame(width: 8, height: 8)
            Text(label)
                .font(Typeface.label(11, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
            Text(value.clockText)
                .font(Typeface.number(11))
                .monospacedDigit()
                .foregroundStyle(Palette.primaryText)
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
            fact(WorkHistory.longestStretch(history.days)?.longestStretch.hoursText ?? "—",
                 caption: "longest unbroken\nstretch")
            fact(WorkHistory.medianDesk(history.days).hoursText,
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

    private var peak: Double { max(rhythm.max() ?? 0, 1) }
    private var peakHour: Int? { WorkHistory.peakHour(rhythm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    bar(hour)
                }
            }
            .frame(height: 92)

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
            .frame(height: max(1, 92 * share))
            .frame(maxWidth: .infinity, alignment: .bottom)
            .help("\(String(format: "%02d", hour)):00 — \((rhythm[hour]).hoursText)")
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
