import SwiftUI

/// One bar per day.
///
/// Every range but Today is drawn this way. An hourly chart summed over thirty
/// days answers a question about habits; this app is about how long a day ran,
/// and only a day can answer that.
struct DayChart: View {
    let days: [WorkDay]
    let pointer: PointerTracker

    static let gap: CGFloat = 2
    static let height: CGFloat = 92

    private var peak: Double { max(days.map(\.desk).max() ?? 0, 1) }
    private var average: Double {
        let worked = days.map(\.desk).filter { $0 > 0 }
        guard !worked.isEmpty else { return 0 }
        return worked.reduce(0, +) / Double(worked.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: Self.gap) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Palette.control)
                            .frame(height: max(1, Self.height * (day.desk / peak)))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                // A single hue, and the line is what makes an outlier visible.
                //
                // Days whose longest sit passed ninety minutes were tinted red
                // first, and seventeen of thirty-one days came out red — more
                // than half a chart in the alarm colour is a chart with no
                // alarm colour in it. The count already sits in the figures
                // below; the bars did not need to say it again.
                if average > 0 {
                    Rectangle()
                        .fill(Palette.primaryText.opacity(0.28))
                        .frame(height: 1)
                        .offset(y: -Self.height * (average / peak))
                        // The offset repeats on purpose. An overlay added
                        // after `.offset` is laid out against the unshifted
                        // frame, so the label has to be lifted by the same
                        // amount again or it prints along the bottom of the
                        // chart while the line it names sits at the top.
                        .overlay(alignment: .trailing) {
                            Text("avg \(average.clockText)")
                                .font(Typeface.number(8.5))
                                .monospacedDigit()
                                .foregroundStyle(Palette.faintText)
                                .padding(.horizontal, 3)
                                .background(Palette.surface)
                                .offset(y: -Self.height * (average / peak))
                        }
                }
            }
            .frame(height: Self.height)
            .overlay { DayTooltip(days: days, pointer: pointer) }

            labels
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// Every fifth day, and always the last, so a month does not print thirty
    /// numbers four points apart.
    private var labels: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                Text(index % 5 == 0 || index == days.count - 1 ? Self.dayNumber(day) : "")
                    .font(Typeface.number(8.5))
                    .foregroundStyle(Palette.faintText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            if average > 0 {
                Text("average ")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    + Text(average.clockText)
                    .font(Typeface.number(10.5))
                    .foregroundStyle(Palette.primaryText)
                    + Text(" a day")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            if let busiest = days.max(by: { $0.desk < $1.desk }), busiest.desk > 0 {
                Text("busiest ")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    + Text(Self.shortDate(busiest))
                    .font(Typeface.number(10.5))
                    .foregroundStyle(Palette.primaryText)
                    + Text(", \(busiest.desk.clockText)")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.top, 4)
    }

    private var summary: String {
        guard average > 0 else { return "No days recorded yet." }
        return "\(days.count) days, averaging \(average.clockText) at the desk."
    }

    // MARK: Dates

    /// The stored key is `yyyy-MM-dd`, and reading it back with a formatter
    /// would be parsing this app's own string through a locale that might
    /// disagree with it.
    static func parts(_ day: WorkDay) -> (year: Int, month: Int, day: Int)? {
        let bits = day.day.split(separator: "-").compactMap { Int($0) }
        guard bits.count == 3 else { return nil }
        return (bits[0], bits[1], bits[2])
    }

    static func dayNumber(_ day: WorkDay) -> String {
        parts(day).map { "\($0.day)" } ?? ""
    }

    static let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func shortDate(_ day: WorkDay) -> String {
        guard let p = parts(day), months.indices.contains(p.month) else { return day.day }
        return "\(p.day) \(months[p.month])"
    }

    static func longDate(_ day: WorkDay, calendar: Calendar = .current) -> String {
        guard let p = parts(day), months.indices.contains(p.month) else { return day.day }
        guard let date = WorkHistory.date(forKey: day.day, calendar: calendar) else {
            return "\(p.day) \(months[p.month])"
        }
        let weekday = calendar.component(.weekday, from: date)
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let name = names.indices.contains(weekday) ? names[weekday] : ""
        return "\(name) \(p.day) \(months[p.month])"
    }

    /// Minutes past midnight as a clock reading.
    static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }
}

/// Which day the pointer is over.
struct DayHit {
    let index: Int
    let rect: CGRect

    /// Returns nil outside the chart and inside the gap between two bars, so a
    /// card never names a day the pointer is not on.
    static func at(_ point: CGPoint, in bounds: CGRect, count: Int, height: CGFloat) -> DayHit? {
        guard bounds.width > 0, count > 0 else { return nil }
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        guard local.x >= 0, local.x < bounds.width, local.y >= 0, local.y <= height else { return nil }

        let gaps = CGFloat(count - 1) * DayChart.gap
        let width = (bounds.width - gaps) / CGFloat(count)
        guard width > 0 else { return nil }
        let pitch = width + DayChart.gap

        let index = Int(local.x / pitch)
        guard index < count else { return nil }
        let rect = CGRect(x: CGFloat(index) * pitch, y: 0, width: width, height: height)
        guard local.x <= rect.maxX else { return nil }
        return DayHit(index: index, rect: rect)
    }
}

/// The card that names the day under the pointer, and what it was made of.
///
/// The bar's height says how long. Only the breakdown says whether that was an
/// ordinary working day or one that ran to midnight, which is the difference
/// this app exists to show.
private struct DayTooltip: View {
    let days: [WorkDay]
    @ObservedObject var pointer: PointerTracker

    @State private var cardSize = CGSize(width: 176, height: 96)

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            if let hit = DayHit.at(pointer.location ?? .init(x: -1, y: -1), in: bounds,
                                   count: days.count, height: DayChart.height),
               days.indices.contains(hit.index) {
                Rectangle()
                    .fill(Palette.primaryText.opacity(0.07))
                    .frame(width: hit.rect.width + 2, height: DayChart.height)
                    .position(x: hit.rect.midX, y: DayChart.height / 2)

                Card(day: days[hit.index])
                    .measureSize { size in
                        Task { @MainActor in if size != .zero, size != cardSize { cardSize = size } }
                    }
                    .position(
                        x: min(max(hit.rect.midX, cardSize.width / 2),
                               max(bounds.width - cardSize.width / 2, cardSize.width / 2)),
                        y: cardSize.height / 2 + 3)
            }
        }
        .allowsHitTesting(false)
    }

    private struct Card: View {
        let day: WorkDay

        /// Bands with nothing in them are left out rather than printed as zero,
        /// so an ordinary day shows three rows and a day that ran past midnight
        /// grows a fourth. That fourth is tinted, and it only appears when there
        /// is something to notice — which is what stops the tint becoming
        /// wallpaper.
        private var bands: [(band: DayBand, seconds: Double)] {
            WorkHistory.bands(day).filter { $0.seconds >= 30 }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(day.desk.clockText)
                        .font(Typeface.number(12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.primaryText)
                    Text("at the desk")
                        .font(Typeface.label(9.5))
                        .foregroundStyle(Palette.faintText)
                }
                Text(subtitle)
                    .font(Typeface.number(9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faintText)
                    .padding(.top, 3)

                if !bands.isEmpty {
                    Rectangle().fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(bands, id: \.band.id) { entry in
                            row(entry.band, entry.seconds)
                        }
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

        /// The day's own span beside the date. The bands are fixed six-hour
        /// windows; this is when the day actually started and stopped, and
        /// 11:18 against a 06:00 boundary is the difference between a long
        /// morning and a late start.
        private var subtitle: String {
            let date = DayChart.longDate(day)
            guard let first = day.firstMinute, let last = day.lastMinute else { return date }
            return "\(date) · \(DayChart.time(first)) – \(DayChart.time(last))"
        }

        private func row(_ band: DayBand, _ seconds: Double) -> some View {
            HStack(spacing: 8) {
                Text(seconds.clockText)
                    .font(Typeface.number(10.5))
                    .monospacedDigit()
                    .foregroundStyle(band == .night ? Palette.critical : Palette.primaryText)
                    .frame(width: 46, alignment: .trailing)
                Text(band.name)
                    .font(Typeface.label(10, weight: .medium))
                    .foregroundStyle(band == .night ? Palette.critical.opacity(0.85) : Palette.secondaryText)
                    .frame(width: 60, alignment: .leading)
                Text(band.window)
                    .font(Typeface.number(9.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faintText)
            }
        }
    }
}
