import SwiftUI

/// What sits beside the notch when nothing is hovered.
///
/// Two strips with a hole between them the exact width of the notch. The hole
/// is the whole trick: content that stops dead at the notch's edge and picks up
/// again on the far side reads as *going behind* it, which is what makes the
/// strips look like part of the hardware instead of an overlay near it.
///
/// The strip is sized by its own content with matched padding at both outer
/// ends. It used to be a fixed 464-point bar with both sides hugging the notch,
/// which left the outer third of it empty at each end — the thing that made it
/// look pasted on rather than machined.
///
/// No gauges and no rings: two figures in tabular mono either side of a
/// hairline, and the day's tokens across the hole. This is the state that is on
/// screen all day, so it earns the least ink.
struct IdleStripView: View {
    /// Reports both sides' laid-out widths together, which is what decides how
    /// far the whole strip has to slide for its hole to land on the notch.
    let onFlanks: (CGFloat, CGFloat) -> Void
    /// Most recent first, at most two.
    let recent: [ProviderSnapshot]
    let today: ScanReport
    let showing: StripContent
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let isStale: Bool

    var body: some View {
        StripFlanks(report: onFlanks) {
            HStack(spacing: 10) {
                ForEach(Array(recent.prefix(2).enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.16))
                            .frame(width: 1, height: 12)
                    }
                    AgentChip(snapshot: snapshot)
                }
            }
            .fixedSize()
            .padding(.leading, Metrics.stripPad)
            .padding(.trailing, Metrics.stripNotchGap)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 5) {
                if showing.showsTokens {
                    Text(today.totalTokens.compactTokens)
                        .font(Typeface.number(11.5))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white.opacity(0.95))
                        .monospacedDigit()
                    Text("tok")
                        .font(Typeface.label(9, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white.opacity(0.35))
                        .textCase(.uppercase)
                        .kerning(0.5)
                }
                if showing.showsCost {
                    Text(today.totalCost.compactMoney)
                        .font(Typeface.number(11))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white.opacity(showing == .both ? 0.55 : 0.95))
                        .monospacedDigit()
                        .padding(.leading, showing == .both ? 3 : 0)
                }
            }
            .fixedSize()
            .padding(.leading, Metrics.stripNotchGap)
            .padding(.trailing, Metrics.stripPad)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(today.totalTokens.grouped) tokens today, \(today.totalCost.compactMoney)")
        }
        .frame(height: notchHeight)
        .opacity(isStale ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.3), value: isStale)
    }
}

/// One tool beside the notch: its mark, and how much of its session is left.
///
/// The mark carries the brand colour and the number stays white — a row of
/// coloured percentages is a row of things to decode, while a white figure next
/// to a coloured mark reads as a label on a thing. The figure takes colour only
/// when it is the thing: red, in the last fifteen percent.
struct AgentChip: View {
    let snapshot: ProviderSnapshot

    @ObservedObject private var activity = AgentActivity.shared
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spent: Double { 1 - snapshot.sessionLeftFraction }
    private var isCritical: Bool { spent >= Palette.criticalSpent }

    /// The animation runs only when this agent is actually working, the user
    /// has not switched it off, and the system is not asking for less motion.
    /// Everything it says is also said by the figure beside it, so switching it
    /// off costs no information.
    private var level: ActivityLevel? {
        guard !reduceMotion else { return nil }
        return activity.levels[snapshot.brand]
    }

    private var sprite: [[String]]? {
        guard level != nil else { return nil }
        return preferences.activityStyle.frames
    }

    var body: some View {
        HStack(spacing: 4) {
            // In place of the mark, not beside it: same eleven points, same
            // colour, no second object and no change of width. A red figure
            // still wins — at that point "act now" outranks "who".
            if let sprite, let level {
                PixelSprite(frames: sprite,
                            color: isCritical ? Palette.critical : snapshot.brand.color,
                            size: 10,
                            cycle: preferences.activityBeat * level.pace)
                    .opacity(level.opacity)
            } else {
                BrandMark(brand: snapshot.brand, size: 10,
                          tint: isCritical ? Palette.critical : nil)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Int((snapshot.sessionLeftFraction * 100).rounded()))")
                    .font(Typeface.number(11.5))
                    .monospacedDigit()
                // The strip drops the word "left" but keeps the sign: standing
                // alone on a menu bar, "89" does not say what it is a count of.
                Text("%")
                    .font(Typeface.number(8.5))
                    .opacity(0.5)
                    .padding(.leading, 1)
            }
            .foregroundStyle(isCritical ? Palette.critical : .white.opacity(0.95))
            .lineLimit(1)
            .fixedSize()
        }
        .fixedSize()
        .help("\(snapshot.provider) — \(snapshot.sessionMetric?.label ?? "quota") \(snapshot.sessionLeftText) left")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(snapshot.provider), \(snapshot.sessionLeftText) of \(snapshot.sessionMetric?.label ?? "quota") left")
    }
}

/// The idle state with nothing to report yet — a single dim dot, so the strip
/// does not flash a row of zeroes on launch before the first fetch lands.
struct IdlePlaceholder: View {
    let onFlanks: (CGFloat, CGFloat) -> Void
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        StripFlanks(report: onFlanks) {
            Circle()
                .fill(.white.opacity(0.34))
                .frame(width: 5, height: 5)
                .padding(.leading, Metrics.stripPad)
                .padding(.trailing, Metrics.stripNotchGap)
                Color.clear.frame(width: notchWidth)
            Color.clear.frame(width: Metrics.stripPad + Metrics.stripNotchGap + 5)
            }
        .frame(height: notchHeight)
    }
}


// MARK: - Landing the hole on the notch

/// An `HStack` that also says how wide each side of the notch came out.
///
/// The two widths have to be read from the *same* layout pass. Measuring them
/// as two independent views was correct at rest and wrong in between: whichever
/// side reported first had its new width paired with the other side's previous
/// one, and the strip sat visibly off the notch until the second report landed.
/// A `Layout` sees both at once, so the pair is never mismatched.
///
/// Placement is a plain left-to-right stack — this measures, it does not
/// arrange. Where the strip ends up is `StripBalance`'s business.
struct StripFlanks: Layout {
    let report: (CGFloat, CGFloat) -> Void

    private func widths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: widths(subviews).reduce(0, +),
            height: subviews.reduce(0) { max($0, $1.sizeThatFits(.unspecified).height) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(subviews)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index]
        }
        // Leading, notch, trailing.
        if widths.count == 3 { report(widths[0], widths[2]) }
    }
}

/// The one piece of arithmetic in the strip that cannot be left to an `HStack`.
///
/// An `HStack` centres its *total* width, so a 110-point left group and a
/// 75-point right group put the reserved column 17 points right of centre — and
/// the notch does not move. Everything the left group drew in that overhang was
/// painted into the camera cutout, where there are no pixels: it vanished on the
/// machine while still appearing in screenshots, because a screengrab fills the
/// cutout in from the framebuffer, which is how it survived review.
///
/// Padding both flanks to the wider one's width fixes the hole and was the first
/// thing tried. It is wrong: it buys the alignment with a slab of dead black off
/// the narrow end. So the strip keeps its natural, asymmetric width and the
/// whole shape slides instead — half the difference between the flanks, which
/// is exactly enough to put the hole back over the camera while both ends stay
/// hugged to their content.
enum StripBalance {
    static func shift(leading: CGFloat, trailing: CGFloat) -> CGFloat {
        (trailing - leading) / 2
    }

}
