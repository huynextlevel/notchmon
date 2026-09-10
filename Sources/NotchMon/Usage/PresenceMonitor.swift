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

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        last = Date()
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
    }

    private func suspend() {
        sleeping = true
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
        let sample = Presence.sample(
            agentWorking: activity.levels.values.contains(.lively),
            inSession: activity.active(within: Presence.sessionWindow, now: moment))
        let before = clock
        clock = WorkClock.advance(clock, sample: sample, elapsed: elapsed, now: moment)
        isPresent = sample.isPresent

        // The difference, not the total: history accumulates its own days, and
        // the clock resets at midnight while history must not lose the day it
        // is closing.
        let desk = max(0, clock.desk - (clock.day == before.day ? before.desk : 0))
        let coding = max(0, clock.coding - (clock.day == before.day ? before.coding : 0))
        WorkHistory.shared.record(desk: desk, coding: coding,
                                  stretch: clock.sitting(at: moment), at: moment)
    }
}
