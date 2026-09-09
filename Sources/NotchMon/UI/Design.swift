import AppKit
import SwiftUI

/// Sizes, in points, measured against a real 14-inch MacBook Pro: the notch is
/// 220 x 38 and the menu bar is 39 tall. Nothing here assumes those numbers —
/// the notch's own size always comes from `NotchGeometry` — but they are what
/// the proportions were chosen against.
enum Metrics {
    /// The panel never changes size; only the shape drawn inside it does. Both
    /// numbers are ceilings, not layout — wide and tall enough for the largest
    /// the notch can grow.
    static let panelWidth: CGFloat = 760
    static let panelHeight: CGFloat = 520

    static let expandedWidth: CGFloat = 660

    /// The corner flare, and why the content inset is not simply "some padding".
    ///
    /// The flare pulls the shape's BODY in by this much on each side: below the
    /// first `flare` points the drawable edge is at `flare`, not at zero. An
    /// inset quoted against the outer box therefore leaves a gap of
    /// `inset - flare` — which, at the 20 points this started with, was two.
    static let expandedTopRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 26
    /// Clear space between content and the shape's body edge.
    static let bodyMargin: CGFloat = 16
    static var contentInset: CGFloat { expandedTopRadius + bodyMargin }
    static let bottomInset: CGFloat = 22
    /// The row that carries the tabs and the two action buttons. It sits below
    /// the notch band, on the panel's own inset, so it lines up with the hero.
    static let controlRow: CGFloat = 37
    /// Clear space each side of the rule between two sections.
    static let sectionGap: CGFloat = 13

    /// Idle keeps a tight flare so the strip reads as the notch's own moulding.
    static let idleTopRadius: CGFloat = 9
    static let idleBottomRadius: CGFloat = 12
    /// Outer padding at each end of the strip, and the clearance either side of
    /// the notch itself. Matched, so the strip is symmetric about the hole.
    static let stripPad: CGFloat = 14
    static let stripNotchGap: CGFloat = 12

    static let rowHeight: CGFloat = 20
    static let barHeight: CGFloat = 5
    static let windowLabelWidth: CGFloat = 74
    static let windowValueWidth: CGFloat = 92
    static let resetColumnWidth: CGFloat = 58

    /// Activity grid. The cells are sized by the layout rather than fixed:
    /// 52 fixed 8-point columns filled under half the panel and clumped left,
    /// which is what made the grid look like a mistake rather than a choice.
    static let activityWeeks = 52
    static let activityGap: CGFloat = 2
}

/// The current theme's tokens, under the names the views already use.
enum Palette {
    /// Pure black, and it has to stay pure black — the strip is continuous with
    /// a hole in the display.
    static let strip = Color.black

    @MainActor static var surface: Color { Theme.current.surface }
    @MainActor static var primaryText: Color { Theme.current.primaryText }
    @MainActor static var secondaryText: Color { Theme.current.secondaryText }
    @MainActor static var faintText: Color { Theme.current.faintText }
    @MainActor static var track: Color { Theme.current.track }
    @MainActor static var hairline: Color { Theme.current.rule }
    @MainActor static var hover: Color { Theme.current.hover }
    @MainActor static var activeFill: Color { Theme.current.activeFill }
    @MainActor static var control: Color { Theme.current.control }
    @MainActor static var critical: Color { Theme.current.critical }
    @MainActor static var caution: Color { Theme.current.caution }
    @MainActor static var night: Color { Theme.current.night }

    /// The share of a window that has to be spent before colour stops meaning
    /// "which agent" and starts meaning "act now".
    ///
    /// The user's own setting rather than a constant, so "Warn me at 75%" and
    /// the point at which a figure turns red are the same line. They were two
    /// different numbers — a fixed 0.85 here, a stored preference over in
    /// Alerts — which meant the app could flash a warning while every figure on
    /// screen was still calmly in brand colour.
    @MainActor static var criticalSpent: Double {
        Double(Preferences.shared.warnAtPercent) / 100
    }

    /// A vendor's colour for most of a window's life; red for the last of it.
    ///
    /// Brand colour is identity, not status. Spending colour on severity any
    /// earlier would make every healthy row look like a warning.
    @MainActor static func tone(_ brand: Brand, spent: Double) -> Color {
        spent >= criticalSpent ? critical : brand.color
    }
}

/// Two faces, matching the prototype's two custom properties exactly.
///
/// `--ui` there is the system sans; `--mono` is a monospace, and it carries
/// every figure in the design — the hero, the dials, the strip, the month
/// labels. This shipped with `.rounded` on the numbers, which is a different
/// face in a different genre: SF Rounded is soft and proportional where the
/// design is squared and tabular, so the panel read as a different product
/// from the one that was approved.
enum Typeface {
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension View {
    /// The pointing hand over anything that answers a click.
    ///
    /// `.set()` rather than `push()`/`pop()`: this panel can be dismissed with
    /// the pointer still inside a control, and the exit half of a push/pop pair
    /// would never run — leaving the whole desktop with a pointing hand.
    func clickable() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

/// The SF Symbols this app calls by name, in one place so the set stays one
/// weight and one style. Outline throughout: a filled glyph beside outline ones
/// out-ranks them, and none of these deserves to.
enum Symbol {
    static let overview = "gauge.with.dots.needle.33percent"
    // A folder, not a stack of cards: the page answers "which project ate
    // the quota", and the row it lists is a place on disk.
    static let projects = "folder"
    /// A clock face rather than an hourglass or a stopwatch: the page is about
    /// the hours of a day, not about elapsed measurement.
    static let time = "clock"
    static let refresh = "arrow.clockwise"
    static let settings = "gearshape"
    static let pin = "pin"
    static let pinned = "pin.fill"
    static let quit = "togglepower"
}

extension Double {
    /// Money in full. What the panel prints, because it has the width and
    /// because "$83" for $82.69 is a rounding the reader cannot undo.
    var money: String {
        self >= 10_000 ? String(format: "$%.0f", self) : String(format: "$%.2f", self)
    }

    /// Money, kept short enough for the strip: cents below ten dollars, whole
    /// dollars above, because a fourth digit is what pushes the strip into the
    /// menu bar's territory.
    var compactMoney: String {
        if self >= 1000 { return String(format: "$%.1fk", self / 1000) }
        if self >= 10 { return String(format: "$%.0f", self) }
        return String(format: "$%.2f", self)
    }
}

extension Int {
    var compactTokens: String {
        let value = Double(self)
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(self)"
    }

    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

extension Date {
    /// "just now", "4m ago", "2h ago" — how old the numbers on screen are.
    ///
    /// Coarse on purpose. The exact second a poll landed is noise; the only
    /// thing this has to answer is whether what you are reading is current or
    /// whether the fetch has been failing quietly for an hour.
    var agoNow: String {
        let seconds = -timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// "2h 14m", "6d 4h" — a countdown, not a clock time, because what you want
    /// to know about a quota window is how long you have, not when it ends.
    var untilNow: String? {
        let seconds = timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 { return hours >= 10 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        // Hours are kept on a multi-day countdown up to a week: a weekly window
        // shown as "6d" hides up to twenty-three hours, and whether a limit
        // comes back tonight or tomorrow evening is the difference between
        // waiting it out and switching tools.
        if days < 7 { return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h" }
        return "\(days)d"
    }
}
