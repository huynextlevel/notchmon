import SwiftUI

// MARK: - Formatting

extension TimeInterval {
    /// `47m`, `1h47m`. Compact because every place this appears is tight, and
    /// tabular because a figure that changes width every minute makes the whole
    /// row twitch.
    var clockText: String {
        let total = Int(max(0, self))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h\(String(format: "%02d", minutes))m"
    }

    /// The same reading as `clockText`, split so the unit can be set smaller
    /// beside a large figure.
    ///
    /// There used to be a second format here — `%.1fh`, always in hours — and
    /// it is why the longest stretch of a short day read `0.6h`. Nobody thinks
    /// in tenths of an hour. Under an hour a duration is minutes, over it is
    /// hours and minutes, and that is true on the strip, in the band and under
    /// the chart alike.
    var figureAndUnit: (figure: String, unit: String) {
        let total = Int(max(0, self))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return ("\(minutes)", "m") }
        return ("\(hours)", "h\(String(format: "%02d", minutes))m")
    }
}

/// How far a stretch has gone, as the three states the readout has.
enum StretchTone {
    case calm, warn, over

    static func of(_ stretch: TimeInterval) -> StretchTone {
        if stretch >= Presence.restAfter { return .over }
        if stretch >= Presence.warnAfter { return .warn }
        return .calm
    }

    @MainActor var color: Color {
        switch self {
        case .calm: return .white.opacity(0.95)
        case .warn: return Palette.caution
        case .over: return Palette.critical
        }
    }
}

// MARK: - The strip

/// How long you have been sitting, on the strip, always.
///
/// This is the variant that was chosen over an ambient gauge and a
/// threshold-only lozenge, and its cost is stated rather than hidden: it takes
/// the spend figure's place, and a number that is always there is a number you
/// watch. Past the rest threshold it also breathes — the only motion, and only
/// then.
struct SatChip: View {
    let stretch: TimeInterval

    @ObservedObject private var nudges = NudgeCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private var tone: StretchTone { .of(stretch) }

    var body: some View {
        HStack(spacing: 4) {
            // The inline rung, and the cheapest thing the app can do with the
            // half-hour finding: the figure grows a picture of what to do about
            // itself. Nothing opens, nothing is laid out differently, and the
            // strip is the same height it was a second ago.
            if let mark = nudges.mark {
                // Three loops when it arrives, then one loop every forty
                // seconds. A mark that never stops moving is what makes a
                // person switch the reminders off; a mark that never moves is
                // one they never see.
                PixelSprite(frames: reduceMotion ? [mark.frames[0]] : mark.frames,
                            color: mark.tone.color, size: 10, cycle: mark.cycle,
                            hold: BreakLadder.announcing(mark, since: nudges.markedAt)
                                  ? 0 : BreakLadder.markHold)
                    .padding(.trailing, 1)
            }
            Text(stretch.clockText)
                .font(Typeface.number(11.5))
                .monospacedDigit()
                .foregroundStyle(tone.color)
                .opacity(dim ? 0.45 : 1)
            // The word matters: "1h47m" alone on a menu bar does not say what
            // it is a count of, the same reason the quota chip keeps its "%".
            Text("sat")
                .font(Typeface.label(9, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(tone == .calm ? .white.opacity(0.35) : tone.color.opacity(0.6))
        }
        .fixedSize()
        .onAppear { beat() }
        .onChange(of: tone == .over) { _, _ in beat() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nudges.mark.map { "Sitting \(stretch.clockText). \($0.title)." }
                            ?? "Sitting \(stretch.clockText)")
        .help(nudges.mark?.title ?? "Sitting \(stretch.clockText)")
    }

    private func beat() {
        guard !reduceMotion, tone == .over else { dim = false; return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
    }
}

// MARK: - Shared pieces

/// The current stretch against the rest threshold.
///
/// The threshold is drawn as a tick inside the track rather than as the track's
/// end, because a bar that fills to 100% says "finished" and this one says
/// "past the mark" — those are different, and the bar keeps going.
struct StretchGauge: View {
    let stretch: TimeInterval
    var caption: String = "of 90m"

    private var tone: StretchTone { .of(stretch) }

    var body: some View {
        HStack(spacing: 11) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule()
                        .fill(tone == .calm ? Palette.control : tone.color)
                        .frame(width: geometry.size.width * Presence.toward(stretch))
                    Rectangle()
                        .fill(Palette.primaryText.opacity(0.28))
                        .frame(width: 1)
                        .offset(x: geometry.size.width - 1)
                }
            }
            .frame(height: 6)

            Text(stretch.clockText)
                .font(Typeface.number(11))
                .monospacedDigit()
                .foregroundStyle(tone == .calm ? Palette.secondaryText : tone.color)
                .fixedSize()
            Text(caption)
                .font(Typeface.label(10, weight: .medium))
                .foregroundStyle(Palette.faintText)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sitting \(stretch.clockText) of a \(Int(Presence.restAfter / 60)) minute threshold")
    }
}

/// The band on Overview: totals only, and the stretch.
struct TimeBand: View {
    @ObservedObject private var monitor = PresenceMonitor.shared

    var body: some View {
        let clock = monitor.clock
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(clock.desk.clockText)
                    .font(Typeface.number(27))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primaryText)
                Text("at the desk")
                    .font(Typeface.label(12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 12)
            }
            StretchGauge(stretch: clock.sitting(at: monitor.now))
        }
    }
}
