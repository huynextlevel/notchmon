import SwiftUI

/// The five surfaces the panel can wear.
///
/// A theme changes the panel the notch opens into and nothing else. **The
/// compact strip is `#000` in every one of them and always will be**: it is
/// continuous with a hole in the display, and any lift at all makes the seam
/// between drawn black and moulded black visible.
enum Theme: String, CaseIterable, Identifiable {
    case ink, obsidian, anodized, sable, vapor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ink: return "Ink"
        case .obsidian: return "Obsidian"
        case .anodized: return "Anodized"
        case .sable: return "Sable"
        case .vapor: return "Vapor"
        }
    }

    /// Which theme the palette is currently answering for.
    ///
    /// A static rather than an environment value: every view in this app is
    /// main-actor bound and the whole tree re-renders when `Preferences.theme`
    /// publishes, so threading a palette through fifty initialisers would buy
    /// nothing but ceremony.
    @MainActor static var current: Theme = .ink

    // MARK: Tokens

    /// The panel's ground. Never used for the strip.
    var surface: Color {
        switch self {
        case .ink:      return Color(red: 0.031, green: 0.047, blue: 0.078)  // #080C14
        case .obsidian: return .black
        case .anodized: return Color(red: 0.090, green: 0.094, blue: 0.102)  // #17181A
        case .sable:    return Color(red: 0.075, green: 0.063, blue: 0.063)  // #131010
        case .vapor:    return Color(red: 0.082, green: 0.059, blue: 0.133)  // #150F22
        }
    }

    /// The hue every neutral in this theme is biased toward, so a grey reads as
    /// chosen rather than inherited.
    private var tint: Color {
        switch self {
        case .ink:      return Color(red: 0.494, green: 0.659, blue: 0.882)
        case .obsidian: return .white
        case .anodized: return Color(red: 0.776, green: 0.839, blue: 0.922)
        case .sable:    return Color(red: 0.769, green: 0.620, blue: 0.416)
        case .vapor:    return Color(red: 0.698, green: 0.620, blue: 1.000)
        }
    }

    var primaryText: Color {
        switch self {
        case .sable: return Color(red: 0.929, green: 0.902, blue: 0.863)
        default: return tintedText(0.95)
        }
    }
    var secondaryText: Color { tintedText(0.57) }
    var faintText: Color { tintedText(0.35) }

    private func tintedText(_ opacity: Double) -> Color {
        switch self {
        case .obsidian: return .white.opacity(opacity)
        // A text colour that is the theme's own hue lifted toward white, rather
        // than white knocked back — the second reads as dirty on a coloured
        // ground, the first as belonging to it.
        default: return tint.opacity(min(1, opacity + 0.35)).mix(with: .white, by: 0.55)
        }
    }

    var rule: Color { tint.opacity(0.14) }
    var track: Color { tint.opacity(0.15) }
    var hover: Color { tint.opacity(0.10) }
    var activeFill: Color { tint.opacity(0.17) }

    /// The accent for switches and the selected segment.
    ///
    /// The rule everywhere else in this app is that saturated colour belongs to
    /// a vendor — a blue switch would read as an agent. So a control takes the
    /// theme's **own** hue at full strength instead: Ink blue, Sable brass,
    /// Vapor violet. The rule holds and the themes separate further.
    var control: Color {
        switch self {
        case .ink:      return Color(red: 0.357, green: 0.553, blue: 0.937)
        case .obsidian: return Color(red: 0.725, green: 0.745, blue: 0.776)
        case .anodized: return Color(red: 0.624, green: 0.702, blue: 0.800)
        case .sable:    return Color(red: 0.769, green: 0.620, blue: 0.416)
        case .vapor:    return Color(red: 0.655, green: 0.545, blue: 0.980)
        }
    }

    var critical: Color {
        switch self {
        case .ink:      return Color(red: 1.00, green: 0.435, blue: 0.400)
        case .obsidian: return Color(red: 1.00, green: 0.380, blue: 0.349)
        case .anodized: return Color(red: 1.00, green: 0.420, blue: 0.376)
        case .sable:    return Color(red: 0.949, green: 0.439, blue: 0.373)
        case .vapor:    return Color(red: 1.00, green: 0.427, blue: 0.490)
        }
    }

    /// Whether the panel's ground differs from the strip's, and therefore needs
    /// the first band held black so the two do not meet on a hard line.
    var needsSeam: Bool { self != .obsidian }

    /// The two colours the settings swatch is drawn from.
    var swatch: (Color, Color) {
        switch self {
        case .ink:      return (surface, Color(red: 0.086, green: 0.137, blue: 0.227))
        case .obsidian: return (.black, Color(white: 0.04))
        case .anodized: return (surface, Color(red: 0.165, green: 0.176, blue: 0.192))
        case .sable:    return (surface, Color(red: 0.165, green: 0.129, blue: 0.102))
        case .vapor:    return (surface, Color(red: 0.180, green: 0.129, blue: 0.282))
        }
    }
}

private extension Color {
    /// Blends toward another colour. `Color.mix(with:by:)` is macOS 15, and this
    /// app targets 14.
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = min(max(amount, 0), 1)
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * CGFloat(t)),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * CGFloat(t)),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * CGFloat(t)),
            opacity: Double(a.alphaComponent)
        )
    }
}
