import AppKit
import Combine
import Foundation

/// Samples the machine on a timer and keeps the two clocks running.
///
/// A sensor rather than an inference: the app is here while it happens, so it
/// reads idle time directly instead of reconstructing presence from what an
/// agent wrote afterwards. That is what makes the cap on silences unnecessary
/// — it was only ever needed for drawing days this app was not running for.
@MainActor
final class PresenceMonitor: ObservableObject {
    static let shared = PresenceMonitor()

    @Published private(set) var clock = WorkClock(day: Calendar.current.startOfDay(for: Date()))
    @Published private(set) var isPresent = true
    /// Ticks so views depending on the running stretch redraw without each of
    /// them owning a timer.
    @Published private(set) var now = Date()

    /// Fifteen seconds. Short enough that a stretch crossing its threshold is
    /// noticed while it still means something, and one syscall per tick.
    static let interval: TimeInterval = 15

    private var timer: Timer?
    private var last = Date()
    private var sleeping = false
    private var lastClockSave = Date.distantPast
    private var wasQuiet = false
    /// The block that has just ended, kept until somebody is back to be told
    /// about it. Written at the end of a stretch and read at the start of the
    /// next, because those are two different ticks and can be an hour apart.
    private var endedBlock: (length: TimeInterval, project: String?)?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        last = Date()

        // Carry today's totals across a restart.
        //
        // The clock lives in memory and used to begin every launch at zero,
        // so the panel's "at the desk today" was really "since this app
        // started" — 19 minutes on screen against 73 in the file.
        if let today = WorkHistory.shared.today() {
            clock.desk = today.desk
        }
        // And carry the stretch, when the gap is too short to be a break. Only
        // the stretch: `desk` is the file's to answer, and taking it from two
        // places is how a figure ends up counted twice.
        if let saved = ClockFile.load() {
            clock.sittingSince = saved.sittingSince
            clock.awaySince = saved.awaySince
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common` so the clock keeps running while a menu or a drag has the
        // run loop in a tracking mode — the notch panel does exactly that.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        // Sleep and wake are certainties. The timer does not fire while the
        // machine is asleep anyway, but saying so explicitly means the first
        // tick after waking measures from the wake, not from before the lid
        // closed — the clamp in WorkClock is the second line of defence, not
        // the first.
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        WorkHistory.shared.save()
        ClockFile.save(clock)
    }

    /// Written about once a minute rather than every tick: the file is two
    /// hundred bytes and the tolerance it is read against is five minutes, so
    /// four writes a minute would be paying for precision nothing can use.
    private func saveClockIfDue(_ now: Date) {
        guard now.timeIntervalSince(lastClockSave) >= 60 else { return }
        lastClockSave = now
        ClockFile.save(clock, at: now)
    }

    private func suspend() {
        sleeping = true
        ClockFile.save(clock)
        // Mark the absence as starting now rather than waiting to infer it from
        // the gap on the other side. Belt and braces: the gap rule in
        // `WorkClock.advance` catches this on its own, and has to, because this
        // notification does not always arrive.
        clock.awaySince = Date()
        WorkHistory.shared.save()
    }

    private func resume() {
        sleeping = false
        // Nothing between the sleep and now belongs to anybody — but the length
        // of it decides whether the stretch survives, so the gap is handed to
        // the same rule that decides every other absence rather than being
        // settled here.
        let woke = Date()
        if let away = clock.awaySince, woke.timeIntervalSince(away) >= Presence.restTolerance {
            clock.sittingSince = nil
        }
        last = woke
    }

    // MARK: The tick

    private func tick() {
        let moment = Date()
        let elapsed = moment.timeIntervalSince(last)
        last = moment
        now = moment
        guard !sleeping else { return }

        // Agent activity comes from the file watcher, not from hooks.
        //
        // Hooks were reached for here because they had just been built, which
        // is not a reason. They need installing into somebody's settings.json
        // before they say anything at all, and they cover only the handful of
        // tools that have a hook system — so `coding` was structurally zero on
        // every machine. The watcher needs no cooperation, covers every client
        // tokscale knows about, and is the same signal every historical figure
        // on the Time tab was derived from.
        let activity = AgentActivity.shared
        let preferences = Preferences.shared
        // Still asked, and only for one thing: while an agent is producing you
        // may sit still for longer before being counted as gone.
        let sample = Presence.sample(
            agentWorking: activity.levels.values.contains(.lively))
        let before = clock
        clock = WorkClock.advance(clock, sample: sample, elapsed: elapsed, now: moment)
        isPresent = sample.isPresent

        // The difference, not the total: history accumulates its own days, and
        // the clock resets at midnight while history must not lose the day it
        // is closing.
        let desk = max(0, clock.desk - (clock.day == before.day ? before.desk : 0))
        // A stretch that has only just begun: the transition, not the state, or
        // every tick of a two-hour sit would count as another one.
        let sitStarted = before.sittingSince == nil && clock.sittingSince != nil
        // Attributed to whatever was written to most recently, within the same
        // window that decides whether an agent is still "in a session" at all.
        // Wider than the animation's, because a person reading what an agent
        // just produced is still working on that project.
        WorkHistory.shared.record(desk: desk, stretch: clock.sitting(at: moment),
                                  sitStarted: sitStarted,
                                  project: activity.project(within: 10 * 60, now: moment),
                                  at: moment)

        // Told the stretch and which stretch it is, not asked to work either
        // out. `sittingSince` is the identity of the current sit, so a new one
        // clears what has already fired without the centre having to guess
        // from a duration going down.
        // Read once and handed down, so every reminder this tick agrees about
        // whether somebody is on a call. An unreadable device is not a call.
        let quiet = preferences.quietInCalls && (Attention.micInUse() ?? false)
        if quiet != wasQuiet {
            wasQuiet = quiet
            Log.usage.info("microphone \(quiet ? "in use — reminders held" : "free", privacy: .public)")
        }
        NudgeCenter.shared.advance(sitting: clock.sitting(at: moment),
                                   since: clock.sittingSince, now: moment,
                                   enabled: preferences.breakReminders,
                                   ceiling: preferences.nudgeCeiling,
                                   eyes: preferences.eyeReminder,
                                   quiet: quiet)

        // A stretch just ended: remember how long it was, before the clock
        // forgets. It ended when the absence began, not now — `now` is
        // whenever the gap happened to be noticed.
        if let began = before.sittingSince, clock.sittingSince == nil {
            let ended = clock.awaySince ?? moment
            endedBlock = (max(0, ended.timeIntervalSince(began)),
                          // A wide window on purpose: at the end of a block the
                          // last agent write can be half an hour back and the
                          // block still belongs to that project.
                          activity.project(within: 30 * 60, now: began.addingTimeInterval(1)))
        }
        // And somebody is back.
        if let away = before.awaySince, clock.awaySince == nil, sample.isPresent,
           let block = endedBlock {
            endedBlock = nil
            NudgeCenter.shared.summarise(
                block: block.length, away: moment.timeIntervalSince(away),
                project: block.project, now: moment,
                enabled: preferences.breakReminders, quiet: quiet)
        }

        NudgeCenter.shared.dayPassed(
            desk: clock.desk, budget: preferences.dayBudget,
            day: WorkHistory.key(for: moment), now: moment,
            enabled: preferences.breakReminders, quiet: quiet)

        saveClockIfDue(moment)
        note(sample)
    }

    /// What the clock saw, logged when it changes rather than every tick.
    ///
    /// Three rounds of this feature were argued from guesses about which of the
    /// conditions was holding. Logging only the transitions keeps the record
    /// readable and costs nothing on a quiet machine.
    private var lastNoted: String?

    private func note(_ sample: Presence.Sample) {
        let state = "\(sample.isPresent)/\(sample.agentWorking)"
        guard state != lastNoted else { return }
        lastNoted = state
        Log.usage.info("presence present=\(sample.isPresent, privacy: .public) agent=\(sample.agentWorking, privacy: .public) idle=\(Int(sample.idle), privacy: .public)s desk=\(Int(self.clock.desk), privacy: .public)s")
    }
}
