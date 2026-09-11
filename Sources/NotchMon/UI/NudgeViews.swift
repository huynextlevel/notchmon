import SwiftUI

/// The pill: the notch itself, grown.
///
/// Not a second object parked under the strip. The panel draws **one** black
/// shape sized by whatever content it is given, so a taller strip is the same
/// silhouette a few points deeper — which is the whole reason this can look
/// like the hardware opening rather than a window appearing.
///
/// It keeps the hole, and therefore `StripFlanks`: the camera cutout does not
/// move because a reminder arrived, and content that ran across it would be
/// content sitting on the lens.
struct NudgeStripView: View {
    let onFlanks: (CGFloat, CGFloat) -> Void
    let nudge: ActiveNudge
    let sitting: TimeInterval
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Deeper than the notch by design — that overhang is the announcement.
    /// Twelve points: enough to read as opened, not enough to cover a menu.
    static let depth: CGFloat = 12

    var body: some View {
        StripFlanks(report: onFlanks) {
            HStack(spacing: 8) {
                sprite
                VStack(alignment: .leading, spacing: 1) {
                    Text(nudge.headline)
                        .font(Typeface.label(12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(nudge.detail)
                        .font(Typeface.label(9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.leading, Metrics.stripPad)
            .padding(.trailing, Metrics.stripNotchGap)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 4) {
                Text(sitting.clockText)
                    .font(Typeface.number(12))
                    .monospacedDigit()
                    .foregroundStyle(nudge.sprite.tone.color)
                Text("sat")
                    .font(Typeface.label(9, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(nudge.sprite.tone.color.opacity(0.6))
            }
            .fixedSize()
            .padding(.leading, Metrics.stripNotchGap)
            .padding(.trailing, Metrics.stripPad)
        }
        .frame(height: notchHeight + Self.depth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nudge.headline). \(nudge.detail).")
        .accessibilityAddTraits(.isStaticText)
    }

    /// Twice the size it has on the strip, because this is the one moment the
    /// picture is the message rather than a mark beside one.
    @ViewBuilder private var sprite: some View {
        if reduceMotion {
            PixelSprite(frames: [nudge.sprite.frames[0]], color: nudge.sprite.tone.color,
                        size: 20, cycle: 1)
        } else {
            PixelSprite(frames: nudge.sprite.frames, color: nudge.sprite.tone.color,
                        size: 20, cycle: nudge.sprite.cycle)
        }
    }
}

/// The panel rung, at the top of the open panel.
///
/// The two-hour nudge opens the panel, and a panel that opened by itself has to
/// say why on the first line or it reads as a bug. Everything below it is the
/// page that was going to be there anyway — the reminder does not take the
/// panel over, because the Time tab underneath is the evidence for what the
/// banner is claiming.
struct NudgeBanner: View {
    let nudge: ActiveNudge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            PixelSprite(frames: reduceMotion ? [nudge.sprite.frames[0]] : nudge.sprite.frames,
                        color: nudge.sprite.tone.color,
                        size: 44, cycle: nudge.sprite.cycle)
            VStack(alignment: .leading, spacing: 3) {
                Text(nudge.headline)
                    .font(Typeface.label(15, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(nudge.detail)
                    .font(Typeface.label(11.5, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape.fill(nudge.sprite.tone.color.opacity(0.13))
                .overlay { shape.strokeBorder(nudge.sprite.tone.color.opacity(0.35), lineWidth: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}
