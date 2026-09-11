import SwiftUI

/// How loud a reminder is allowed to get.
///
/// Ordered, because the setting that caps it is a ceiling rather than a choice:
/// someone who never wants the panel keeps everything below it.
enum NudgeLevel: Int, Comparable, CaseIterable, Identifiable, SegmentLabelled {
    /// The mark on the strip changes. Nothing opens, nothing moves.
    case inline
    /// The notch itself grows for a few seconds.
    case pill
    /// The whole panel drops down. Once per stretch.
    case panel

    var id: Int { rawValue }
    static func < (a: NudgeLevel, b: NudgeLevel) -> Bool { a.rawValue < b.rawValue }

    var segmentLabel: String {
        switch self {
        case .inline: return "Mark"
        case .pill: return "Notch"
        case .panel: return "Panel"
        }
    }
}

/// Which palette token a sprite is drawn in.
///
/// Not a colour: the app has five themes and the sprite has to follow whichever
/// is on. `night` is the same mix the rhythm chart uses for the hours after
/// 22:00, so a reminder about the small hours matches the chart that reports
/// them.
enum NudgeTone {
    case control, caution, critical, night

    @MainActor var color: Color {
        switch self {
        case .control: return Palette.control
        case .caution: return Palette.caution
        case .critical: return Palette.critical
        case .night: return Palette.night
        }
    }
}

/// One picture, what it asks for, and how it is coloured.
struct BreakSprite: Equatable, Identifiable {
    let id: String
    let frames: [[String]]
    let cycle: Double
    let tone: NudgeTone
    /// Written as an instruction, not a diagnosis. "Two hours in the chair" is
    /// the detail line's job; the title is the thing to do about it.
    let title: String

    static func == (a: BreakSprite, b: BreakSprite) -> Bool { a.id == b.id }
}

extension BreakSprite {
    static let stretch = BreakSprite(id: "stretch", frames: BreakSprites.stretch,
                                     cycle: 1.6, tone: .critical, title: "Stand up and stretch")
    static let coffee  = BreakSprite(id: "coffee", frames: BreakSprites.coffee,
                                     cycle: 1.9, tone: .caution, title: "Worth a coffee?")
    static let water   = BreakSprite(id: "water", frames: BreakSprites.water,
                                     cycle: 2.4, tone: .control, title: "Drink some water")
    static let snack   = BreakSprite(id: "snack", frames: BreakSprites.snack,
                                     cycle: 2.6, tone: .caution, title: "Go get a snack")
    static let rest    = BreakSprite(id: "rest", frames: BreakSprites.rest,
                                     cycle: 2.4, tone: .critical, title: "Time to stand up")
    static let walk    = BreakSprite(id: "walk", frames: BreakSprites.walk,
                                     cycle: 0.9, tone: .critical, title: "Take a walk")
    static let window  = BreakSprite(id: "window", frames: BreakSprites.window,
                                     cycle: 3.0, tone: .control, title: "Look outside")
    static let game    = BreakSprite(id: "game", frames: BreakSprites.game,
                                     cycle: 1.4, tone: .caution, title: "Go play something")
    static let book    = BreakSprite(id: "book", frames: BreakSprites.book,
                                     cycle: 2.4, tone: .control, title: "Read something else")
    static let eyes    = BreakSprite(id: "eyes", frames: BreakSprites.eyes,
                                     cycle: 3.0, tone: .control, title: "Look at something far")
    static let moon    = BreakSprite(id: "moon", frames: BreakSprites.moon,
                                     cycle: 2.6, tone: .night, title: "It's past midnight")
    static let done    = BreakSprite(id: "back", frames: BreakSprites.back,
                                     cycle: 0.7, tone: .control, title: "Break taken")
}

/// One rung.
struct BreakStep: Equatable, Identifiable {
    let after: TimeInterval
    let level: NudgeLevel
    /// More than one so the same picture is not the answer every hour of every
    /// day. Which one is picked is deterministic — see `BreakLadder.sprite`.
    let pool: [BreakSprite]

    var id: TimeInterval { after }
}

/// When a reminder fires, and how loud.
///
/// The intervals are not a matter of taste. Five minutes of walking every 30
/// was the only pattern that moved both blood pressure and post-meal glucose in
/// Diaz's 2023 trial, and the 2015 sedentary-office statement asks for a change
/// of posture on the same half hour. Directive 90/270 requires screen work to
/// be broken up without naming a number; the working benchmark is 5–10 minutes
/// away every 50–60 and no continuous screen hour. Breaks of ten minutes or
/// less were enough to cut fatigue and raise vigour across the 22 studies in
/// Albulescu's 2022 meta-analysis.
///
/// So the interval follows the evidence and **the cost of the interruption
/// follows the risk**. Thirty minutes is the strongest finding and gets the
/// cheapest possible response, because an app that opens the notch every half
/// hour is switched off inside a week — and a reminder that has been switched
/// off is worth nothing.
enum BreakLadder {
    /// Off by default, and deliberately: 20-20-20 is recommended everywhere and
    /// has not tested well — two weeks of it moved none of the objective
    /// measures in the trial the 2022 Ophthalmology review reports. Worth
    /// offering, not worth imposing.
    static let eyesAfter: TimeInterval = 20 * 60

    /// How long an opened reminder stays on screen.
    ///
    /// It was three loops of the sprite — five to eight seconds — and that was
    /// measured, not guessed, to be the whole of the bug: the ladder fired on
    /// time and the notch opened correctly, for seven seconds, at the top edge
    /// of a sixteen-inch screen, in silence. Ninety one-second captures of a
    /// real sit caught it in seven frames. Something that asks you to stop
    /// working cannot be shorter than the gap between glances at the menu bar.
    ///
    /// Thirty seconds is still short enough that it cannot be *in the way* —
    /// it does not block a click, it takes no keyboard, and it goes without
    /// being dismissed.
    static let pillFor: TimeInterval = 30
    /// The panel is the whole top of the screen, so it earns less patience.
    static let panelFor: TimeInterval = 15

    /// How long the strip's mark stays still between passes.
    ///
    /// The mark is on screen for the rest of the sit — half an hour, sometimes
    /// three. Continuous motion for that long is the thing that gets the whole
    /// feature switched off; no motion at all is not seen, because peripheral
    /// vision reports change rather than state. So it announces itself for
    /// three loops when it arrives, and after that moves once every forty
    /// seconds: often enough to be caught on a glance, rare enough that it is
    /// never what you are looking at.
    static let markHold: TimeInterval = 40

    static func duration(for level: NudgeLevel) -> TimeInterval {
        level == .panel ? panelFor : pillFor
    }

    /// How long a newly arrived mark keeps moving before it settles.
    static func announcing(_ sprite: BreakSprite, since: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(since) < sprite.cycle * 3
    }

    static let steps: [BreakStep] = [
        BreakStep(after: 30 * 60, level: .inline, pool: [.stretch]),
        BreakStep(after: 60 * 60, level: .pill, pool: [.coffee, .water, .snack]),
        BreakStep(after: 90 * 60, level: .pill, pool: [.rest, .walk]),
        BreakStep(after: 120 * 60, level: .panel, pool: [.game, .book, .window])
    ]

    /// The highest rung this stretch has reached.
    static func step(at stretch: TimeInterval) -> BreakStep? {
        steps.last { stretch >= $0.after }
    }

    /// Which of a rung's pictures to use.
    ///
    /// Rotated by a seed the caller owns rather than chosen at random: the same
    /// nudge arriving twice in one stretch must not change its mind about what
    /// it is asking for, and a reminder that is random is a reminder that
    /// cannot be recognised.
    static func sprite(for step: BreakStep, seed: Int) -> BreakSprite {
        step.pool[((seed % step.pool.count) + step.pool.count) % step.pool.count]
    }

    /// What the strip's mark should be, given the stretch so far.
    ///
    /// The mark carries the current rung's picture the whole time, not only in
    /// the second the pill opens. The pill is that same suggestion said out
    /// loud; between them the strip keeps showing it quietly, which is what
    /// makes the pill read as the same voice rather than a new one.
    static func mark(at stretch: TimeInterval, eyes: Bool, seed: Int) -> BreakSprite? {
        if let step = step(at: stretch) { return sprite(for: step, seed: seed) }
        if eyes, stretch >= eyesAfter { return .eyes }
        return nil
    }
}

/// A reminder that is on screen now.
struct ActiveNudge: Equatable, Identifiable {
    let sprite: BreakSprite
    let level: NudgeLevel
    /// The line under the title. Built by the centre, which is the only thing
    /// that knows the real figures.
    let detail: String
    let until: Date

    var id: String { sprite.id }
}

/// Decides when a reminder fires, and remembers that it has.
///
/// Separate from `PresenceMonitor` on purpose. The monitor's job is to be right
/// about whether somebody is there, and it has been wrong in expensive ways
/// before — an overnight lid-close once read as a nine-hour sit. Deciding to
/// interrupt somebody is a second job with a different failure mode, and mixing
/// them would mean every change to one risks the other.
@MainActor
final class NudgeCenter: ObservableObject {
    static let shared = NudgeCenter()

    /// The pill or the panel, while it is up.
    @Published private(set) var active: ActiveNudge?
    /// What the strip's mark should be. Nil until the first rung.
    @Published private(set) var mark: BreakSprite?
    /// When the mark last changed, which is what decides whether it is still
    /// announcing itself or has settled into its slow beat.
    @Published private(set) var markedAt = Date.distantPast

    /// Which rungs have already fired in this stretch, by their `after`.
    private var fired: Set<TimeInterval> = []
    /// The stretch these belong to. A new sit clears the record.
    private var stretch: Date?
    /// How many nudges have been raised since launch, which is what rotates the
    /// pictures.
    private var raised = 0
    /// Takes the reminder away on its own clock.
    ///
    /// The expiry cannot be left to the next presence tick: that runs every
    /// fifteen seconds, so a pill meant to be up for seven would sit there for
    /// fifteen, and a four-second one would be indistinguishable from it. What
    /// is on screen has to be governed by the same number that was chosen for
    /// it.
    private var expiry: DispatchWorkItem?

    /// Called from the presence tick. The settings arrive as arguments rather
    /// than being read from `Preferences.shared`: this decides whether to
    /// interrupt somebody, and a decision that reaches for a global is one that
    /// cannot be tested without writing to the user's real defaults.
    ///
    /// Everything here is a pure function of the clock plus what has already
    /// fired, so a missed tick cannot leave a reminder half-raised.
    func advance(sitting: TimeInterval, since: Date?, now: Date = Date(),
                 enabled: Bool, ceiling: NudgeLevel, eyes: Bool) {
        if since != stretch {
            stretch = since
            fired.removeAll()
            clear()
        }

        guard enabled else {
            if mark != nil { mark = nil }
            clear()
            return
        }

        let next = BreakLadder.mark(at: sitting, eyes: eyes, seed: raised)
        if next != mark {
            mark = next
            markedAt = now
        }

        if let up = active, now >= up.until { clear() }

        for step in BreakLadder.steps where sitting >= step.after && !fired.contains(step.after) {
            fired.insert(step.after)
            raise(step, sitting: sitting, now: now, ceiling: ceiling)
        }
    }

    /// Clears everything, for the switch in Settings and for a display change.
    func stand(down: Bool = true) {
        guard down else { return }
        clear()
        mark = nil
    }

    private func clear() {
        expiry?.cancel()
        expiry = nil
        if active != nil { active = nil }
    }

    private func raise(_ step: BreakStep, sitting: TimeInterval, now: Date, ceiling: NudgeLevel) {
        let level = min(step.level, ceiling)
        // A rung capped down to `inline` has nothing to open — the mark is
        // already carrying it. It still counts as fired, so raising the ceiling
        // later does not fire the whole ladder at once.
        guard level > .inline else { return }
        raised += 1
        let sprite = BreakLadder.sprite(for: step, seed: raised)
        if mark != sprite {
            mark = sprite
            markedAt = now
        }
        clear()
        active = ActiveNudge(
            sprite: sprite,
            level: level,
            detail: detail(for: step, sitting: sitting),
            // It takes itself away, but not before it has had a chance to be
            // seen — see `BreakLadder.pillFor`.
            until: now.addingTimeInterval(BreakLadder.duration(for: level)))

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.expire(sprite.id) }
        }
        expiry = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BreakLadder.duration(for: level), execute: work)

        Log.usage.info("break nudge: \(sprite.id, privacy: .public) at \(Int(sitting / 60), privacy: .public)m, \(String(describing: level), privacy: .public)")
    }

    /// Named rather than unconditional, so a nudge raised while an older one
    /// was still counting down cannot be taken away by the older one's timer.
    private func expire(_ id: String) {
        guard active?.sprite.id == id else { return }
        clear()
    }

    private func detail(for step: BreakStep, sitting: TimeInterval) -> String {
        step.level == .panel
            ? "\(sitting.clockText) sitting, and it has said so twice"
            : "\(sitting.clockText) without a break"
    }
}
