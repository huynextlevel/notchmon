import SwiftUI

/// When in the week the work actually happens.
///
/// The day chart answers "how much" and the hour chart answers "when, today".
/// Neither answers the question a month of data is actually for: whether
/// Tuesday afternoon is real and whether Sunday is. Seven rows by twenty-four
/// columns, from buckets the history already keeps — nothing new is recorded
/// for this, so the picture cannot disagree with the charts above it.
struct WeekGrid: View {
    let days: [WorkDay]
    let pointer: PointerTracker

    static let rowHeight: CGFloat = 13
    static let gap: CGFloat = 2

    private var grid: [[Double]] { WorkHistory.rhythm(days) }
    private var peak: Double { max(grid.flatMap { $0 }.max() ?? 0, 1) }

    /// The heaviest cell, named rather than left to be found.
    private var busiest: (day: Int, hour: Int, seconds: Double)? {
        var best: (Int, Int, Double)?
        for (row, hours) in grid.enumerated() {
            for (hour, seconds) in hours.enumerated() where seconds > 0 {
                if seconds > (best?.2 ?? 0) { best = (row, hour, seconds) }
            }
        }
        return best.map { (day: $0.0, hour: $0.1, seconds: $0.2) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(WorkHistory.weekdayNames[row])
                            .font(Typeface.number(8.5))
                            .foregroundStyle(Palette.faintText)
                            .frame(height: Self.rowHeight)
                    }
                }
                .fixedSize()

                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        HStack(spacing: Self.gap) {
                            ForEach(0..<24, id: \.self) { hour in
                                cell(grid[row][hour], hour: hour)
                            }
                        }
                        .frame(height: Self.rowHeight)
                    }
                    hours
                }
                .overlay { WeekTooltip(grid: grid, pointer: pointer) }
            }
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// Four steps, not a continuous ramp. A shade per second is a shade nobody
    /// can compare across a grid this small; four say empty, some, most, peak.
    private func cell(_ seconds: Double, hour: Int) -> some View {
        let share = seconds / peak
        let step: Double = seconds <= 0 ? 0 : (share > 0.66 ? 1 : (share > 0.33 ? 0.62 : 0.3))
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(step == 0
                  ? Palette.track.opacity(0.5)
                  : (WorkHistory.isNight(hour) ? Palette.night : Palette.control).opacity(step))
            .frame(maxWidth: .infinity)
    }

    private var hours: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour % 6 == 0 ? String(format: "%02d", hour) : "")
                    .font(Typeface.number(8.5))
                    .foregroundStyle(Palette.faintText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            if let busiest, busiest.seconds > 0 {
                Text("busiest ")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    + Text("\(WorkHistory.weekdayNames[busiest.day]) \(String(format: "%02d", busiest.hour)):00")
                    .font(Typeface.number(10.5))
                    .foregroundStyle(Palette.primaryText)
                    + Text(", \(busiest.seconds.clockText) across the range")
                    .font(Typeface.label(10.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.top, 4)
    }

    private var summary: String {
        guard let busiest, busiest.seconds > 0 else { return "No week recorded yet." }
        return "Desk time by weekday and hour. Busiest "
            + "\(WorkHistory.weekdayNames[busiest.day]) at \(busiest.hour):00."
    }
}

/// Which cell the pointer is over.
struct WeekHit {
    let day: Int
    let hour: Int
    let rect: CGRect

    static func at(_ point: CGPoint, in bounds: CGRect) -> WeekHit? {
        guard bounds.width > 0 else { return nil }
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        let pitchY = WeekGrid.rowHeight + WeekGrid.gap
        let rows = pitchY * 7
        guard local.x >= 0, local.x < bounds.width, local.y >= 0, local.y < rows else { return nil }

        let width = (bounds.width - CGFloat(23) * WeekGrid.gap) / 24
        guard width > 0 else { return nil }
        let pitchX = width + WeekGrid.gap

        let hour = Int(local.x / pitchX), day = Int(local.y / pitchY)
        guard hour < 24, day < 7 else { return nil }
        let rect = CGRect(x: CGFloat(hour) * pitchX, y: CGFloat(day) * pitchY,
                          width: width, height: WeekGrid.rowHeight)
        guard local.x <= rect.maxX, local.y <= rect.maxY else { return nil }
        return WeekHit(day: day, hour: hour, rect: rect)
    }
}

private struct WeekTooltip: View {
    let grid: [[Double]]
    @ObservedObject var pointer: PointerTracker

    @State private var cardSize = CGSize(width: 132, height: 34)

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            if let hit = WeekHit.at(pointer.location ?? .init(x: -1, y: -1), in: bounds),
               grid.indices.contains(hit.day) {
                Rectangle()
                    .fill(Palette.primaryText.opacity(0.10))
                    .frame(width: hit.rect.width + 2, height: hit.rect.height + 2)
                    .position(x: hit.rect.midX, y: hit.rect.midY)

                Card(day: hit.day, hour: hit.hour, seconds: grid[hit.day][hit.hour])
                    .measureSize { size in
                        Task { @MainActor in if size != .zero, size != cardSize { cardSize = size } }
                    }
                    .position(
                        x: min(max(hit.rect.midX, cardSize.width / 2),
                               max(bounds.width - cardSize.width / 2, cardSize.width / 2)),
                        y: max(cardSize.height / 2, hit.rect.minY - 6 - cardSize.height / 2))
            }
        }
        .allowsHitTesting(false)
    }

    private struct Card: View {
        let day: Int
        let hour: Int
        let seconds: Double

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(seconds > 0 ? seconds.clockText : "none")
                    .font(Typeface.number(11.5))
                    .monospacedDigit()
                    .foregroundStyle(seconds > 0 ? Palette.primaryText : Palette.faintText)
                Text("\(WorkHistory.weekdayNames[day]) \(String(format: "%02d:00", hour))")
                    .font(Typeface.number(9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faintText)
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
