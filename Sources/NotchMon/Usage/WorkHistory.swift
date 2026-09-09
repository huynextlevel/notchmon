import Combine
import Foundation

/// One day, as much of it as this app was running for.
///
/// The hour buckets are what the rhythm chart is drawn from, and they are kept
/// per day rather than as one rolling set of 24 totals so the window can be
/// changed later without having thrown the detail away.
struct WorkDay: Codable, Equatable, Identifiable {
    /// `yyyy-MM-dd` in local time. A string because the file is read by a
    /// person as often as by the app, and because a `Date` key would drift with
    /// the timezone it was written in.
    var day: String
    var desk: TimeInterval = 0
    var coding: TimeInterval = 0
    /// Seconds at the desk in each clock hour, 0…23.
    var hours: [Double] = Array(repeating: 0, count: 24)
    /// The longest unbroken stretch of sitting seen on this day.
    var longestStretch: TimeInterval = 0

    var id: String { day }
}

/// Every day this app has watched.
///
/// Persisted for the same reason the quota history is: the figures worth
/// showing are the ones that took a month to gather, and an app that forgets
/// them on quit can only ever show today.
@MainActor
final class WorkHistory: ObservableObject {
    static let shared = WorkHistory()

    /// Oldest first.
    @Published private(set) var days: [WorkDay] = []

    /// Long enough for a month's rhythm to be worth drawing, short enough that
    /// the file stays small and a habit from last spring does not colour this
    /// week's chart.
    static let keptDays = 90
    /// What the tab draws from.
    static let windowDays = 30

    private var isLoaded = false
    private var lastSave = Date.distantPast
    private static let saveInterval: TimeInterval = 60

    private init() {}

    // MARK: Recording

    /// Fold one tick's worth of presence into today.
    func record(desk seconds: TimeInterval, coding: TimeInterval,
                stretch: TimeInterval, at now: Date, calendar: Calendar = .current) {
        loadIfNeeded()
        guard seconds > 0 || stretch > 0 else { return }

        let key = Self.key(for: now, calendar: calendar)
        var day = days.last?.day == key ? days.removeLast() : (days.first { $0.day == key }.map {
            // Not the last entry: the app was running across a midnight and the
            // day came back. Rare, and cheap to handle properly.
            days.removeAll { $0.day == key }
            return $0
        } ?? WorkDay(day: key))

        day.desk += seconds
        day.coding += coding
        day.longestStretch = max(day.longestStretch, stretch)
        let hour = calendar.component(.hour, from: now)
        if hour >= 0, hour < 24 { day.hours[hour] += seconds }

        days.append(day)
        days.sort { $0.day < $1.day }
        if days.count > Self.keptDays { days.removeFirst(days.count - Self.keptDays) }

        if now.timeIntervalSince(lastSave) >= Self.saveInterval { save() }
    }

    // MARK: Derived — pure, so the figures on the tab can be tested

    /// Seconds at the desk per clock hour across the window.
    static func rhythm(_ days: [WorkDay]) -> [Double] {
        var out = Array(repeating: 0.0, count: 24)
        for day in days.suffix(windowDays) {
            for (i, seconds) in day.hours.enumerated() where i < 24 { out[i] += seconds }
        }
        return out
    }

    /// The hour with the most time in it, or nil when there is none.
    static func peakHour(_ rhythm: [Double]) -> Int? {
        guard let best = rhythm.max(), best > 0 else { return nil }
        return rhythm.firstIndex(of: best)
    }

    /// The share of the window spent between 22:00 and 06:00.
    ///
    /// Not a curiosity: it is the figure most likely to change somebody's
    /// evening, which is what this whole feature is for.
    static func nightShare(_ rhythm: [Double]) -> Double {
        let total = rhythm.reduce(0, +)
        guard total > 0 else { return 0 }
        var night = 0.0
        for hour in 0..<24 where isNight(hour) { night += rhythm[hour] }
        return night / total
    }

    static func isNight(_ hour: Int) -> Bool { hour >= 22 || hour < 6 }

    /// Days in the window with any work on them.
    static func activeDays(_ days: [WorkDay]) -> Int {
        days.suffix(windowDays).count { $0.desk > 0 }
    }

    /// Days whose longest stretch ran past the rest threshold.
    static func daysOverThreshold(_ days: [WorkDay],
                                  threshold: TimeInterval = Presence.restAfter) -> Int {
        days.suffix(windowDays).count { $0.longestStretch >= threshold }
    }

    /// The middle day, which says more about a habit than the mean: one
    /// eleven-hour day drags an average and leaves the typical day unstated.
    static func medianDesk(_ days: [WorkDay]) -> TimeInterval {
        let worked = days.suffix(windowDays).map(\.desk).filter { $0 > 0 }.sorted()
        guard !worked.isEmpty else { return 0 }
        return worked[worked.count / 2]
    }

    static func longestStretch(_ days: [WorkDay]) -> WorkDay? {
        days.suffix(windowDays).max { $0.longestStretch < $1.longestStretch }
            .flatMap { $0.longestStretch > 0 ? $0 : nil }
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Storage

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NotchMon", isDirectory: true)
            .appendingPathComponent("work-history.json")
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            days = try JSONDecoder().decode([WorkDay].self, from: data).sorted { $0.day < $1.day }
            Log.usage.info("work history loaded: \(self.days.count, privacy: .public) days")
        } catch {
            // Same rule as the quota history: a file this app wrote and cannot
            // read is a schema change. Starting over costs a month of chart and
            // is silent; refusing to start costs the tab entirely.
            Log.usage.error("work history unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            days = []
        }
    }

    func save() {
        lastSave = Date()
        let url = Self.fileURL
        let snapshot = days
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.usage.error("work history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
