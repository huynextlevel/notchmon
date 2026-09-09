import NotchMonBridge
import SwiftUI

/// The state of one session, as a shape as well as a colour.
///
/// Shape and not only colour, because three states told apart by hue alone are
/// three states nobody with a colour deficiency can read — and at six points,
/// on black, that is most people at a glance.
struct StateDot: View {
    let status: SessionStatus
    var size: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Group {
            switch status {
            case .working:
                // Filled and breathing: producing something right now.
                Circle().fill(Palette.control)
                    .scaleEffect(pulse ? 1 : 0.8)
                    .opacity(pulse ? 1 : 0.5)
            case .waiting:
                // Hollow: stopped, and the hole is the point — nothing is being
                // produced until you come back.
                Circle().strokeBorder(Palette.critical, lineWidth: 1.5)
            case .compacting:
                Circle().strokeBorder(Palette.secondaryText, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .rotationEffect(.degrees(pulse ? 360 : 0))
            case .ended, .unknown:
                Circle().fill(Palette.faintText)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion, status == .working || status == .compacting else { return }
            withAnimation(animation) { pulse = true }
        }
    }

    private var animation: Animation {
        status == .working
            ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
            : .linear(duration: 3.4).repeatForever(autoreverses: false)
    }
}

/// The one thing the strip says when a session wants you back.
///
/// It replaces the token and spend figures rather than sitting beside them.
/// That is the trade this design makes: on an ordinary day the strip is exactly
/// what it was, and the moment it is not, the thing that changed is the only
/// thing there.
struct BatonView: View {
    let baton: Baton

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ping = false

    var body: some View {
        HStack(spacing: 6) {
            StateDot(status: .waiting, size: 7)
                .overlay {
                    // The ring pushed outward and faded — a knock, not a blink.
                    // Drawn outside the dot so nothing about the dot moves.
                    if !reduceMotion {
                        Circle()
                            .stroke(Palette.critical, lineWidth: 1)
                            .scaleEffect(ping ? 2.2 : 1)
                            .opacity(ping ? 0 : 0.55)
                    }
                }

            Text(baton.title)
                .font(Typeface.label(11, weight: .semibold))
                .foregroundStyle(Palette.critical)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("needs you")
                .font(Typeface.label(10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)

            if baton.others > 0 {
                // Kept out of the title. The lozenge names one session; this
                // says only that it is not the whole story.
                Text("+\(baton.others)")
                    .font(Typeface.number(9.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.critical.opacity(0.75))
            }
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.critical.opacity(0.17))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.critical.opacity(0.45), lineWidth: 1))
        )
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { ping = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        let who = SessionResolve.agentLabel(baton.session.agent)
        let more = baton.others > 0 ? ", and \(baton.others) more waiting" : ""
        return "\(baton.title) needs you — \(who)\(more)"
    }
}

/// Every live session, in the two groups that mean different things.
struct SessionsSection: View {
    let sessions: [AgentSession]

    private var split: (waiting: [AgentSession], running: [AgentSession]) {
        SessionResolve.split(sessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !split.waiting.isEmpty {
                Eyebrow("Needs you", tone: Palette.critical)
                rows(split.waiting)
            }
            if !split.running.isEmpty {
                if !split.waiting.isEmpty { Spacer().frame(height: 6) }
                Eyebrow("Running")
                RunningLine(sessions: split.running)
            }
        }
    }

    @ViewBuilder
    private func rows(_ list: [AgentSession]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { session in
                SessionRow(session: session)
                if session.id != list.last?.id {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
        }
    }
}

/// What is alive, in one line.
///
/// This was a row each — a state pill and a timer per session — and it earned
/// none of it. "tokscale is working, three minutes" asks nothing of the person
/// reading it: there is no decision attached, and the agent chips beside the
/// notch already say which tools are alive. The one fact those chips cannot
/// carry is *which projects*, since a chip is per brand and four Claude windows
/// are one chip. So that is all this keeps.
struct RunningLine: View {
    let sessions: [AgentSession]

    /// Four names is about what fits before the line starts truncating; past
    /// that a count says more than half a name would.
    private var shown: [AgentSession] { Array(sessions.prefix(4)) }
    private var rest: Int { sessions.count - shown.count }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(shown) { session in
                HStack(spacing: 5) {
                    StateDot(status: session.status, size: 5)
                    Text(SessionResolve.title(for: session))
                        .font(Typeface.label(11.5, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if rest > 0 {
                Text("+\(rest)")
                    .font(Typeface.number(10.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faintText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running: " + sessions.map { SessionResolve.title(for: $0) }
            .joined(separator: ", "))
    }
}

/// One session that wants you back: what it is called, what is running it, and
/// how long it has been asking.
struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 11) {
            StateDot(status: session.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(SessionResolve.title(for: session))
                    .font(Typeface.label(12.5, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(Typeface.number(10.5))
                    .foregroundStyle(Palette.faintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Text(session.status.title)
                .font(Typeface.label(9.5, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(tone)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.14)))

            Text(age)
                .font(Typeface.number(11))
                .monospacedDigit()
                .foregroundStyle(Palette.faintText)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(SessionResolve.title(for: session)), \(SessionResolve.agentLabel(session.agent)), \(session.status.title), \(age) ago")
    }

    private var tone: Color {
        switch session.status {
        case .waiting: return Palette.critical
        case .working: return Palette.control
        default: return Palette.secondaryText
        }
    }

    /// The tool beside the terminal it is in — the two things that say which
    /// window this is, which is what the row exists to answer.
    private var meta: String {
        var parts = [SessionResolve.agentLabel(session.agent)]
        if let tool = session.tool, !tool.isEmpty { parts.append(tool) }
        if let tty = session.tty, !tty.isEmpty { parts.append(tty) }
        return parts.joined(separator: " · ")
    }

    private var age: String {
        let seconds = max(0, Date().timeIntervalSince(session.updated))
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
}

extension SessionStatus {
    /// Sentence case for the panel; the view uppercases it for the pill.
    var title: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compacting"
        case .ended: return "Ended"
        case .unknown: return "Unknown"
        }
    }
}
