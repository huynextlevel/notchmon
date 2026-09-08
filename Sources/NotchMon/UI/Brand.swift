import SwiftUI

/// Who a provider is, visually: its colour and its mark.
///
/// One brand can arrive under two names. tokscale's quota call says "Claude"
/// and "Codex"; its token scan says `claude` and `codex`; a Gemini quota is
/// spent through the `antigravity` client. `match` folds all of that onto one
/// case, which is what lets the recency of a *client* be pinned onto the ring
/// of a *provider*.
enum Brand: String, CaseIterable {
    case claude, openai, cursor, copilot, gemini, antigravity, glm, grok
    case opencode, openrouter, minimax, kimi, deepseek, perplexity, generic

    static func match(_ name: String) -> Brand {
        let n = name.lowercased()
        if n.contains("claude") || n.contains("anthropic") { return .claude }
        if n.contains("codex") || n.contains("openai") || n.contains("chatgpt") { return .openai }
        if n.contains("cursor") { return .cursor }
        if n.contains("copilot") { return .copilot }
        if n.contains("antigravity") { return .antigravity }
        if n.contains("gemini") || n.contains("google") { return .gemini }
        if n.contains("glm") || n.contains("zhipu") || n == "zai" || n == "zcode" { return .glm }
        if n.contains("grok") || n.contains("xai") { return .grok }
        if n.contains("opencode") { return .opencode }
        if n.contains("openrouter") { return .openrouter }
        if n.contains("minimax") { return .minimax }
        if n.contains("kimi") || n.contains("moonshot") { return .kimi }
        if n.contains("deepseek") { return .deepseek }
        if n.contains("perplexity") { return .perplexity }
        return .generic
    }

    /// The brand's own accent, tuned for a black ground.
    ///
    /// Two of these are white on purpose. OpenAI, Cursor and Grok are
    /// monochrome marks; painting them a colour they do not own would make
    /// the strip *less* recognisable, not more. White on the notch's black is
    /// exactly how those logos appear in their own dark UIs.
    var color: Color {
        switch self {
        case .claude:      return Color(red: 0.85, green: 0.47, blue: 0.34)   // #D97757
        case .openai:      return Color.white.opacity(0.92)
        case .cursor:      return Color.white.opacity(0.92)
        case .copilot:     return Color(red: 0.55, green: 0.49, blue: 0.96)   // #8B7CF6
        case .gemini:      return Color(red: 0.31, green: 0.55, blue: 0.96)   // #4E8DF5
        case .antigravity: return Color(red: 0.31, green: 0.55, blue: 0.96)
        case .glm:         return Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6
        case .grok:        return Color.white.opacity(0.92)
        case .opencode:    return Color.white.opacity(0.85)
        case .openrouter:  return Color(red: 0.39, green: 0.40, blue: 0.95)   // #6467F2
        case .minimax:     return Color(red: 1.00, green: 0.31, blue: 0.31)   // #FF4F4F
        case .kimi:        return Color(red: 0.04, green: 0.76, blue: 0.66)   // #0BC3A8
        case .deepseek:    return Color(red: 0.30, green: 0.42, blue: 1.00)   // #4D6BFE
        case .perplexity:  return Color(red: 0.13, green: 0.72, blue: 0.80)   // #20B8CD
        case .generic:     return Color(red: 0.60, green: 0.63, blue: 0.65)   // #9AA0A6
        }
    }

    /// The traced mark, or nil for a brand no outline has been traced for.
    var outline: [[CGPoint]]? {
        switch self {
        case .claude:      return GlyphOutline.claude
        case .openai:      return GlyphOutline.openai
        case .cursor:      return GlyphOutline.cursor
        case .gemini:      return GlyphOutline.gemini
        case .antigravity: return GlyphOutline.antigravity
        case .glm:         return GlyphOutline.glm
        case .grok:        return GlyphOutline.grok
        case .opencode:    return GlyphOutline.opencode
        default:           return nil
        }
    }

    /// Evens out ink between marks whose unit boxes are the same size but whose
    /// shapes are not — a spark is mostly empty corners, a knot is mostly ink.
    var opticalScale: CGFloat {
        switch self {
        case .claude, .cursor: return 0.97
        case .openai:          return 0.94
        case .glm, .opencode:  return 0.95
        default:               return 1.0
        }
    }
}

/// A traced outline scaled into the view's bounds, filled even-odd so the
/// counters inside a knot stay open.
struct GlyphShape: Shape {
    let outline: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: rect))
            for p in loop.dropFirst() { path.addLine(to: point(p, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

/// GitHub Copilot's goggles, drawn rather than traced: a rounded visor with
/// two lenses cut out even-odd. Recognisable at 12 points, which is all the
/// strip asks of it.
struct CopilotShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let visor = CGRect(
            x: rect.minX, y: rect.minY + rect.height * 0.18,
            width: rect.width, height: rect.height * 0.64
        )
        path.addRoundedRect(in: visor, cornerSize: CGSize(width: visor.height * 0.42, height: visor.height * 0.42))
        let lensW = rect.width * 0.24
        let lensH = visor.height * 0.44
        let lensY = visor.midY - lensH / 2
        path.addRoundedRect(
            in: CGRect(x: rect.minX + rect.width * 0.20, y: lensY, width: lensW, height: lensH),
            cornerSize: CGSize(width: lensW * 0.35, height: lensW * 0.35)
        )
        path.addRoundedRect(
            in: CGRect(x: rect.maxX - rect.width * 0.20 - lensW, y: lensY, width: lensW, height: lensH),
            cornerSize: CGSize(width: lensW * 0.35, height: lensW * 0.35)
        )
        return path
    }
}

/// The brand's mark in the brand's colour, at a fixed size.
struct BrandMark: View {
    let brand: Brand
    var size: CGFloat = 12
    var tint: Color?

    var body: some View {
        Group {
            if let outline = brand.outline {
                GlyphShape(outline: outline)
                    .fill(tint ?? brand.color, style: FillStyle(eoFill: true))
                    .scaleEffect(brand.opticalScale)
            } else if brand == .copilot {
                CopilotShape()
                    .fill(tint ?? brand.color, style: FillStyle(eoFill: true))
            } else {
                Circle()
                    .strokeBorder(tint ?? brand.color, lineWidth: max(size * 0.14, 1.5))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
