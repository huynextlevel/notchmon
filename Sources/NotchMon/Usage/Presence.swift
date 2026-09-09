import AppKit
import CoreGraphics
import Foundation

/// Whether there is a person at this machine.
///
/// Deliberately separate from whether an agent is working. Those are two
/// different questions and conflating them was the first mistake in this
/// design: a break reminder driven by agent activity stops counting the moment
/// you switch to reading documentation in a browser — even though you have been
/// sitting for three hours, which is the only thing your back and eyes care
/// about.
///
/// So: presence answers "are you at the desk", agent activity answers "are you
/// coding", and coding time is a subset of desk time.
enum Presence {

    /// No input for this long and nobody is here.
    ///
    /// Generous on purpose. Reading a long answer without touching anything is
    /// ordinary, and the cost of the two errors is not symmetric: undercounting
    /// makes the reminder late, overcounting nags you about a rest you just
    /// took, which is how this kind of app gets deleted.
    static let idleTolerance: TimeInterval = 5 * 60

    /// The same question while an agent is mid-task.
    ///
    /// Watching a build run for ten minutes produces no keystrokes and no hook
    /// events — `PreToolUse` fires once at the start and nothing until it
    /// finishes. The person is probably watching it. *Probably*: they may also
    /// have gone for coffee precisely because it was going to take ten minutes.
    /// So this stretches the tolerance rather than suspending it.
    static let watchingTolerance: TimeInterval = 15 * 60

    /// Where coding happens.
    ///
    /// An agent writing is not evidence that a person is coding. Measured on
    /// this machine while it was getting this wrong: an agent was writing to
    /// `~/.claude/projects` every few seconds, so a session was open by every
    /// test the clock had — and the frontmost application was a browser playing
    /// video. The clock counted it as coding to within a minute of the desk
    /// time. The missing question was never "is an agent running" but "are you
    /// looking at the work".
    ///
    /// A list like this is wrong the day somebody installs a terminal it has
    /// never heard of, and that failure undercounts, which is the direction
    /// already chosen everywhere else here. It costs an accurate figure; it
    /// does not cost a wrong one.
    static let codingSurfaces: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "io.alacritty", "co.zeit.hyper", "com.raphaelamorim.rio", "app.tabby.Terminal",
        // Editors and IDEs
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",            // Cursor
        "dev.zed.Zed", "com.apple.dt.Xcode", "com.exafunction.windsurf",
        "com.trae.app", "com.google.android.studio",
        "com.neovide.neovide", "org.vim.MacVim",
    ]

    /// Families whose members all count, so a version bump or an edition does
    /// not have to be listed one at a time.
    static let codingSurfacePrefixes: [String] = [
        "com.jetbrains.",       // IntelliJ, PyCharm, GoLand, RustRover, …
        "com.sublimetext.",
        "com.microsoft.VSCode", // Insiders, Exploration
    ]

    static func isCodingSurface(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if codingSurfaces.contains(bundleID) { return true }
        return codingSurfacePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// How long after an agent's last write you are still counted as being in
    /// a session.
    ///
    /// Ten minutes, and the number is not free: every historical figure on the
    /// Time tab was derived by treating a silence of up to ten minutes as one
    /// continuous piece of work. A live clock with a different window would
    /// make today's bar mean something other than the thirty before it.
    static let sessionWindow: TimeInterval = 10 * 60

    /// The stretch at which the readout stops being neutral.
    ///
    /// Not a health claim — the published advice on sitting and on screen
    /// breaks is a range, not a number. It is a first mark on a dial, chosen so
    /// that on this machine's own measured history it is passed most days and
    /// the second mark is passed on about half of them: a signal that fires
    /// every day says nothing, and one that fires monthly is forgotten.
    static let warnAfter: TimeInterval = 60 * 60
    /// And the stretch at which it asks.
    static let restAfter: TimeInterval = 90 * 60

    /// How far through the rest threshold a stretch has run, 0…1.
    static func toward(_ stretch: TimeInterval) -> Double {
        min(1, max(0, stretch / restAfter))
    }

    /// Away for less than this and you have not rested; the sitting stretch
    /// carries on rather than starting again. Standing up for two minutes does
    /// not undo ninety.
    static let restTolerance: TimeInterval = 5 * 60

    /// One reading of the machine.
    struct Sample: Equatable {
        /// Seconds since the last keyboard or mouse event.
        var idle: TimeInterval
        /// Screen locked. Certainty, not inference.
        var locked: Bool
        /// This login session owns the console — false under fast user
        /// switching, when the person in front of the machine is someone else.
        var onConsole: Bool
        /// Display awake. A closed lid is not a person.
        var displayOn: Bool
        /// An agent is mid-task right now. This stretches how long you can sit
        /// still before being counted as gone, and nothing else.
        var agentWorking: Bool
        /// An agent has written recently enough that you are still inside a
        /// session. Wider than `agentWorking`, because reading the answer and
        /// typing the next prompt is coding and the machine is silent
        /// throughout.
        var inSession: Bool = false
        /// The frontmost application is a terminal or an editor.
        ///
        /// Required alongside `inSession`, and it is the half that was missing:
        /// an agent grinding away while you watch a video is the agent's time,
        /// not yours.
        var attending: Bool = false

        /// Coding is being in a session *and* looking at it.
        var isCoding: Bool { inSession && attending }

        /// The three hard negatives are answered first because they are facts.
        /// Only when none of them applies does idle time — which is evidence,
        /// not proof — get a say.
        var isPresent: Bool {
            guard !locked, onConsole, displayOn else { return false }
            return idle < (agentWorking ? watchingTolerance : idleTolerance)
        }
    }

    // MARK: Reading the machine

    /// Every value here was checked on a real machine before being relied on,
    /// and none of them asks the user for a permission.
    @MainActor
    static func sample(agentWorking: Bool, inSession: Bool = false) -> Sample {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return Sample(
            idle: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput),
            locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            // Absent key means this *is* the console session; assuming the
            // hostile reading would stop the clock on every ordinary machine.
            onConsole: session?["kCGSSessionOnConsoleKey"] as? Bool ?? true,
            displayOn: CGDisplayIsActive(CGMainDisplayID()) != 0,
            agentWorking: agentWorking,
            inSession: inSession,
            attending: isCodingSurface(frontmost))
    }
}

/// How long you have been here, and how much of it was spent coding.
///
/// A value type with one pure transition, so the rules can be tested against
/// invented days rather than by sitting at a desk for three hours.
struct WorkClock: Equatable {
    /// The local day these totals belong to. Totals reset when it changes.
    var day: Date
    /// Time at the machine today.
    var desk: TimeInterval = 0
    /// The part of it with an agent alive. Always `<= desk`.
    var coding: TimeInterval = 0
    /// Start of the current unbroken stretch of sitting, if you are sitting.
    var sittingSince: Date?
    /// When you were last seen, if you are not here now.
    var awaySince: Date?

    /// How long the current stretch has run.
    func sitting(at now: Date) -> TimeInterval {
        guard let sittingSince else { return 0 }
        return max(0, now.timeIntervalSince(sittingSince))
    }

    /// A tick's worth of time is never longer than this, however long the timer
    /// actually slept.
    ///
    /// The timer does not fire while the machine is asleep, so the first tick
    /// after waking reports the whole night. Clamping is what stops a closed
    /// lid from being counted as eight hours at the desk.
    static let maxStep: TimeInterval = 90

    /// Fold one reading in.
    ///
    /// `elapsed` is real time since the previous sample, not the sampling
    /// interval: a busy machine fires timers late, and the difference is time
    /// the person was genuinely here.
    static func advance(_ clock: WorkClock, sample: Presence.Sample,
                        elapsed: TimeInterval, now: Date,
                        calendar: Calendar = .current) -> WorkClock {
        var clock = clock

        let today = calendar.startOfDay(for: now)
        if today != clock.day {
            clock.day = today
            clock.desk = 0
            clock.coding = 0
            // The stretch survives midnight. Sitting from 23:40 to 00:30 is
            // fifty minutes of sitting, not two sessions of twenty-five.
        }

        let step = min(max(0, elapsed), maxStep)

        guard sample.isPresent else {
            // First sample of an absence records when it started; later ones
            // leave it alone, so the length of the absence keeps growing.
            if clock.awaySince == nil { clock.awaySince = now }
            if let away = clock.awaySince, now.timeIntervalSince(away) >= Presence.restTolerance {
                clock.sittingSince = nil
            }
            return clock
        }

        clock.desk += step
        if sample.isCoding { clock.coding += step }

        if let away = clock.awaySince {
            // Back after a real rest: the stretch starts again from now. Back
            // after two minutes: it never stopped.
            if now.timeIntervalSince(away) >= Presence.restTolerance {
                clock.sittingSince = now
            }
            clock.awaySince = nil
        }
        if clock.sittingSince == nil { clock.sittingSince = now }
        return clock
    }
}
