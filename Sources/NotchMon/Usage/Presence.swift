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
    static func sample(agentWorking: Bool) -> Sample {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return Sample(
            idle: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput),
            locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            // Absent key means this *is* the console session; assuming the
            // hostile reading would stop the clock on every ordinary machine.
            onConsole: session?["kCGSSessionOnConsoleKey"] as? Bool ?? true,
            displayOn: CGDisplayIsActive(CGMainDisplayID()) != 0,
            agentWorking: agentWorking)
    }
}

/// How long you have been here, and how much of it was spent coding.
///
/// A value type with one pure transition, so the rules can be tested against
/// invented days rather than by sitting at a desk for three hours.
struct WorkClock: Equatable, Codable {
    /// The local day these totals belong to. Totals reset when it changes.
    var day: Date
    /// Time at the machine today.
    var desk: TimeInterval = 0
    /// Start of the current unbroken stretch of sitting, if you are sitting.
    var sittingSince: Date?
    /// When you were last seen, if you are not here now.
    var awaySince: Date?

    /// How long the current stretch has run.
    func sitting(at now: Date) -> TimeInterval {
        guard let sittingSince else { return 0 }
        return max(0, now.timeIntervalSince(sittingSince))
    }

    /// Whether a clock saved at `savedAt` still describes this moment.
    ///
    /// The same rule the running clock uses, applied to the gap a restart left:
    /// under `restTolerance` is not an absence, so the stretch it was holding
    /// is still the stretch. Over it, and the restart is indistinguishable from
    /// a break — which is what it should be counted as.
    static func survives(_ savedAt: Date, at now: Date = Date()) -> Bool {
        let gap = now.timeIntervalSince(savedAt)
        return gap >= 0 && gap < Presence.restTolerance
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
            // The stretch survives midnight. Sitting from 23:40 to 00:30 is
            // fifty minutes of sitting, not two sessions of twenty-five.
        }

        let step = min(max(0, elapsed), maxStep)

        // A tick that arrives long after the last one is itself the evidence.
        //
        // The clamp above stops a closed lid being banked as desk time, and it
        // was doing that correctly — but the sitting stretch has its own state
        // and nothing was clearing it. The absence branch below only runs when
        // a tick happens *during* the absence, and no tick happens while the
        // machine is asleep: the timer does not fire, so on waking `awaySince`
        // was still nil and `sittingSince` still held last night. Reported from
        // a real morning: four minutes at the desk, and a stretch of 9h11m.
        //
        // Sleep and wake notifications are also observed, but they are not what
        // this rests on. A gap is a fact about time that arrived on its own,
        // and it holds when a notification is missed, when the app was
        // suspended, and when the clock itself was moved.
        if elapsed >= Presence.restTolerance {
            clock.sittingSince = nil
            clock.awaySince = now.addingTimeInterval(-elapsed)
        }

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


/// The clock, across a restart.
///
/// Not restoring it was a deliberate choice and it was wrong in one common
/// case. "A relaunch is not evidence that anybody sat through it" holds for a
/// machine that was off all night; it does not hold for an update that took
/// four seconds, and the app's own rule already says so — a gap under five
/// minutes is not an absence. Without this, every relaunch banked a fresh sit
/// (a screenshot of a normal day claimed twenty of them) and reset the break
/// ladder, so an update at fifty-five minutes meant the hour never arrived.
enum ClockFile {
    struct Snapshot: Codable {
        var clock: WorkClock
        var savedAt: Date
    }

    static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NotchMon", isDirectory: true)
            .appendingPathComponent("clock.json")
    }

    static func save(_ clock: WorkClock, at now: Date = Date()) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(clock: clock, savedAt: now))
            try data.write(to: url, options: .atomic)
        } catch {
            Log.usage.error("clock not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Nil when there is nothing to restore, and nil when what is there is old
    /// enough to be a break. A failed read is the same as no read: the clock
    /// starting at zero undercounts, which is the direction everything here
    /// errs in.
    static func load(at now: Date = Date()) -> WorkClock? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              WorkClock.survives(snapshot.savedAt, at: now)
        else { return nil }
        return snapshot.clock
    }
}
