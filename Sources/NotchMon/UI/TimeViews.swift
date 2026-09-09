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

    /// `5.6h`, for figures read as a quantity rather than a duration.
    var hoursText: String { String(format: "%.1fh", max(0, self) / 3600) }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private var tone: StretchTone { .of(stretch) }

    var body: some View {
        HStack(spacing: 4) {
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
        .accessibilityLabel("Sitting \(stretch.clockText)")
        .help(tone == .over
              ? "Sitting \(stretch.clockText) — worth standing up"
              : "Sitting \(stretch.clockText)")
    }

    private func beat() {
        guard !reduceMotion, tone == .over else { dim = false; return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
    }
}

// MARK: - Shared pieces

/// Desk time with the coding share inside it.
struct DeskSplit: View {
    let desk: TimeInterval
    let coding: TimeInterval
    var height: CGFloat = 7

    private var share: Double { desk > 0 ? min(1, coding / desk) : 0 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.control).frame(width: geometry.size.width * share)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coding.clockText) coding of \(desk.clockText) at the desk")
    }
}

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
                Text(clock.coding.clockText)
                    .font(Typeface.number(12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.control)
                Text("coding")
                    .font(Typeface.label(12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            StretchGauge(stretch: clock.sitting(at: monitor.now))
        }
    }
}
