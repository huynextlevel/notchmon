import SwiftUI

/// A year of daily usage, filling whatever width the panel has.
///
/// It used to be 26 weeks of fixed 8-point cells, which came to 260 points
/// inside a 540-point panel — under half the width, hard left, and reading as a
/// mistake. The cells now size themselves from the available width, so the grid
/// fills the panel exactly at any width, and the range widened to a year so
/// that a comfortable cell size still spans something worth looking at.
///
/// Intensity comes from tokscale's own buckets rather than being re-derived
/// here: whatever thresholds it uses, using them is what keeps this grid
/// agreeing with every other tool reading the same sessions.
struct ActivityGrid: View {
    let pointer: PointerTracker

    /// Laid out once at init rather than in `body`. Building it walks a year of
    /// dates through a `DateFormatter`, and the tooltip needs to index it on
    /// every pointer move.
    private let grid: [[ContributionDay?]]

    static let rows = 7

    init(days: [ContributionDay], pointer: PointerTracker) {
        self.pointer = pointer
        self.grid = Self.columns(from: days)
    }

    /// Weeks laid out so the last column is the current week and each column
    /// runs Sunday to Saturday, which is the grid everyone already knows how to
    /// read. Days with no data are holes, not zeroes — an empty Tuesday and an
    /// unrecorded Tuesday look the same on this grid, and only one of them is
    /// worth distinguishing, which is neither.
    private static func columns(from days: [ContributionDay]) -> [[ContributionDay?]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let today = calendar.startOfDay(for: Date())

        var byDay: [Date: ContributionDay] = [:]
        for day in days {
            if let date = day.day { byDay[calendar.startOfDay(for: date)] = day }
        }

        // Walk back from the end of this week so the grid always ends on a full
        // column rather than a ragged edge.
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let end = calendar.date(byAdding: .day, value: rows - 1 - weekday, to: today)
        else { return [] }

        return (0..<Metrics.activityWeeks).reversed().map { weeksBack -> [ContributionDay?] in
            (0..<rows).map { row -> ContributionDay? in
                let offset = -(weeksBack * rows) - (rows - 1 - row)
                guard let date = calendar.date(byAdding: .day, value: offset, to: end),
                      date <= today
                else { return nil }
                return byDay[calendar.startOfDay(for: date)]
            }
        }
    }

    private var monthLabels: [String] {
        // The formatter carries its own locale. A bare gregorian `Calendar` has
        // none, and its `shortMonthSymbols` came back as "M10", "M11" — correct
        // for a calendar with no language, useless as a label.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let names = formatter.shortMonthSymbols ?? []
        guard names.count == 12 else { return [] }
        let now = Calendar(identifier: .gregorian).component(.month, from: Date()) - 1
        return (0..<12).map { names[(now - 11 + $0 + 24) % 12] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Metrics.activityGap) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: Metrics.activityGap) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            Cell(day: day)
                        }
                    }
                }
            }
            // A sibling of the cells, not part of them. It is the only thing
            // here that watches the pointer, so the 364 cells are not rebuilt
            // twenty-five times a second to move a label.
            .overlay { ActivityTooltipLayer(grid: grid, pointer: pointer) }

            HStack(spacing: 0) {
                ForEach(Array(monthLabels.enumerated()), id: \.offset) { _, month in
                    Text(month)
                        .font(Typeface.number(9, weight: .medium))
                        .foregroundStyle(Palette.faintText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity for the last year")
    }

    private struct Cell: View {
        let day: ContributionDay?

        /// Four steps of the THEME's hue, not an agent's.
        ///
        /// This used to take the colour of whichever agent burned most today,
        /// on the argument that volume is not a different subject from the agent
        /// that produced it. That argument was wrong about what this grid holds:
        /// every square is the sum of every agent that ran that day, so painting
        /// the year in one vendor's colour says a year of Claude, and says it
        /// most loudly on the days another agent did the work.
        ///
        /// It also disagreed with the grid's own empty squares, which have
        /// always been `Palette.track` — the theme's tint. Ink for the ground
        /// and terracotta for the marks made one grid out of two palettes.
        ///
        /// The rule this restores is the app's, stated on `Theme.control`:
        /// saturated colour belongs to a vendor, and anything that is not one
        /// vendor's takes the theme's own hue instead.
        private var fill: Color {
            guard let day, day.intensity > 0 else { return Palette.track }
            switch day.intensity {
            case 1: return Palette.control.opacity(0.28)
            case 2: return Palette.control.opacity(0.52)
            case 3: return Palette.control.opacity(0.76)
            default: return Palette.control
            }
        }

        var body: some View {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(fill)
                // Square, and sized by the column it sits in — the columns are
                // on equal flexible widths, so the grid always ends flush with
                // the panel's inset.
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Which square of the grid a point lands on.
///
/// Pitch arithmetic rather than a tracking area per cell: 364 tracking areas to
/// answer one question is a lot of bookkeeping, and they would not fire anyway —
/// see `PointerTracker`.
struct ActivityHit {
    let column: Int
    let row: Int
    let rect: CGRect
    var day: ContributionDay?

    func carrying(_ day: ContributionDay) -> ActivityHit {
        ActivityHit(column: column, row: row, rect: rect, day: day)
    }

    /// `point` and `bounds` share a coordinate space; `bounds` is the laid-out
    /// grid. Returns nil outside the grid, and inside a gap between squares —
    /// a card that appeared while the pointer was on no square at all would be
    /// naming a day the pointer is not on.
    static func at(_ point: CGPoint, in bounds: CGRect) -> ActivityHit? {
        guard bounds.width > 0 else { return nil }
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        guard local.x >= 0, local.y >= 0, local.x < bounds.width else { return nil }

        let gaps = CGFloat(Metrics.activityWeeks - 1) * Metrics.activityGap
        let side = (bounds.width - gaps) / CGFloat(Metrics.activityWeeks)
        guard side > 0 else { return nil }
        let pitch = side + Metrics.activityGap

        let column = Int(local.x / pitch)
        let row = Int(local.y / pitch)
        guard column < Metrics.activityWeeks, row < ActivityGrid.rows else { return nil }

        let rect = CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch,
                          width: side, height: side)
        guard local.x <= rect.maxX, local.y <= rect.maxY else { return nil }
        return ActivityHit(column: column, row: row, rect: rect, day: nil)
    }
}

/// The card that names the day under the pointer.
///
/// The grid is 364 squares four points wide. Without this, a year of usage is a
/// texture: you can see that August was heavy and February was not, and you
/// cannot read a single figure off it. The card is what turns the texture back
/// into data.
private struct ActivityTooltipLayer: View {
    let grid: [[ContributionDay?]]
    @ObservedObject var pointer: PointerTracker

    /// Seeded with roughly the card's real size so the first frame after a
    /// hover is already in the right place rather than jumping into it.
    @State private var cardSize = CGSize(width: 132, height: 34)

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            if let hit = target(in: bounds), let day = hit.day {
                // A ring around the square, drawn in this overlay rather than
                // on the square itself. Growing or restyling the cell would
                // change its size inside the grid's flexible columns and shove
                // the whole year sideways under the pointer.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Palette.primaryText.opacity(0.75), lineWidth: 1)
                    .frame(width: hit.rect.width + 3, height: hit.rect.height + 3)
                    .position(x: hit.rect.midX, y: hit.rect.midY)
                    .shadow(color: .black.opacity(0.6), radius: 2)

                Card(day: day)
                    // `measureSize`, not a preference — see its own note.
                    .measureSize { size in
                        Task { @MainActor in if size != .zero, size != cardSize { cardSize = size } }
                    }
                    .position(
                        // Held inside the grid so a card on the first or last
                        // week is not half off the panel.
                        x: min(max(hit.rect.midX, cardSize.width / 2),
                               max(bounds.width - cardSize.width / 2, cardSize.width / 2)),
                        y: hit.rect.minY - 6 - cardSize.height / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func target(in bounds: CGRect) -> ActivityHit? {
        guard let location = pointer.location else { return nil }
        guard let hit = ActivityHit.at(location, in: bounds), hit.column < grid.count,
              let day = grid[hit.column][hit.row]
        else { return nil }
        return hit.carrying(day)
    }

    private struct Card: View {
        let day: ContributionDay

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(day.totals.tokens.compactTokens)
                        .font(Typeface.number(12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.primaryText)
                    Text("tokens")
                        .font(Typeface.label(9.5))
                        .foregroundStyle(Palette.faintText)
                    if day.totals.cost > 0 {
                        Text(day.totals.cost.money)
                            .font(Typeface.number(10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Text(day.date)
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

/// A quota as an arc. Starts at twelve o'clock and **drains** clockwise as the
/// window is spent.
///
/// Draining rather than filling, because it has to agree with the words beside
/// it: every figure in this app is what is left, so a ring that grew as you
/// burned quota would be the one element on screen counting the other way.
struct UsageRing: View {
    let remaining: Double
    /// Taken from what has been SPENT, even though the arc draws what is left:
    /// a ring with a sliver remaining should be red, and a sliver of green
    /// would say the opposite.
    let tone: Color
    let size: CGFloat

    private var lineWidth: CGFloat { max(size * 0.17, 2) }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                // A spent window keeps a stub of arc rather than vanishing: an
                // empty track is indistinguishable from a provider that failed
                // to report, and those two need different reactions.
                .trim(from: 0, to: max(remaining, 0.02))
                .stroke(tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.45), value: remaining)
        }
        .frame(width: size, height: size)
    }
}
