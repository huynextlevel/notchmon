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
    /// Seconds at the desk in each clock hour, 0…23.
    var hours: [Double] = Array(repeating: 0, count: 24)
    /// The longest unbroken stretch of sitting seen on this day.
    var longestStretch: TimeInterval = 0
    /// Minutes past local midnight when this day was first and last seen.
    ///
    /// Not derivable from `hours`, which only knows which hour a minute fell
    /// in: a day that starts at 11:18 and one that starts at 11:59 have the
    /// same first bucket and are a very different morning.
    var firstMinute: Int?
    var lastMinute: Int?
    /// How many separate stretches of sitting the day held. One long sit and
    /// six short ones can add to the same total and are not the same day.
    var sits: Int = 0
    /// Seconds at the desk, by project. Keyed exactly as `ProjectUsage` keys
    /// its buckets, so an hour and a dollar can be divided into each other.
    ///
    /// Only what could be attributed. A tick with no agent writing anywhere
    /// belongs to no project and is deliberately left out rather than filed
    /// under a guess — which is why these never sum to `desk`.
    var projects: [String: TimeInterval] = [:]

    var id: String { day }
    /// Desk time that could not be pinned to any project.
    var unattributed: TimeInterval { max(0, desk - projects.values.reduce(0, +)) }
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

    /// Today's row, loading the file if it has not been read yet.
    ///
    /// Exists so the clock can be restored at launch. Without it the panel's
    /// "at the desk today" was really "since this app started", and quitting at
    /// lunchtime silently halved the day.
    ///
    /// A `coding` key written by an earlier version is simply ignored on the
    /// way in, so no history is lost and none of it comes back.
    func today(_ now: Date = Date(), calendar: Calendar = .current) -> WorkDay? {
        loadIfNeeded()
        let key = Self.key(for: now, calendar: calendar)
        return days.first { $0.day == key }
    }

    // MARK: Recording

    /// Fold one tick's worth of presence into today.
    func record(desk seconds: TimeInterval, stretch: TimeInterval,
                sitStarted: Bool = false, project: String? = nil,
                at now: Date, calendar: Calendar = .current) {
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
        // A stretch longer than the day's own desk time is arithmetically
        // impossible and is the shape a bug leaves behind: the overnight
        // failure wrote 9h11m onto a day with fifty minutes on it. Refusing it
        // here means a defect upstream cannot quietly become a permanent figure
        // on the chart.
        day.longestStretch = max(day.longestStretch, min(stretch, day.desk))
        let hour = calendar.component(.hour, from: now)
        if hour >= 0, hour < 24 { day.hours[hour] += seconds }

        if seconds > 0 {
            let minute = hour * 60 + calendar.component(.minute, from: now)
            day.firstMinute = min(day.firstMinute ?? minute, minute)
            day.lastMinute = max(day.lastMinute ?? minute, minute)
        }
        if sitStarted { day.sits += 1 }
        if let project, seconds > 0 { day.projects[project, default: 0] += seconds }

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
    static func medianDesk(_ days: [WorkDay]) -> TimeInterval { median(days.suffix(windowDays)) }

    /// Over exactly the days given, so a range control decides the window
    /// rather than a constant buried here.
    static func median(_ days: some Collection<WorkDay>) -> TimeInterval {
        let worked = days.map(\.desk).filter { $0 > 0 }.sorted()
        guard !worked.isEmpty else { return 0 }
        return worked[worked.count / 2]
    }

    static func longestStretch(_ days: [WorkDay]) -> WorkDay? {
        days.suffix(windowDays).max { $0.longestStretch < $1.longestStretch }
            .flatMap { $0.longestStretch > 0 ? $0 : nil }
    }

    // MARK: Ranges

    /// The days a range covers, oldest first, one entry per calendar day.
    ///
    /// A day with nothing recorded comes back as an empty `WorkDay` rather than
    /// being left out. Thirty stored days and thirty drawn columns is what makes
    /// a gap in the chart mean "nothing here" — dropping the empty days would
    /// redraw four scattered days as four days in a row, which is a different
    /// month.
    static func days(_ days: [WorkDay], in range: TimeRange,
                     now: Date = Date(), calendar: Calendar = .current) -> [WorkDay] {
        let last = calendar.startOfDay(for: now)
        let stored = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, newer in newer })
        return (0..<max(1, range.days)).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: last) else { return nil }
            let key = key(for: date, calendar: calendar)
            return stored[key] ?? WorkDay(day: key)
        }
    }

    /// The inverse of `key(for:)`. Split rather than parsed with a formatter,
    /// which would read this app's own string through a locale that might
    /// disagree with it.
    static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let bits = key.split(separator: "-").compactMap { Int($0) }
        guard bits.count == 3 else { return nil }
        var parts = DateComponents()
        parts.year = bits[0]; parts.month = bits[1]; parts.day = bits[2]
        return calendar.date(from: parts)
    }

    /// A day's time split into the four parts of a day.
    ///
    /// Derived from the hour buckets rather than stored again: four sums of six
    /// numbers, and no second thing to keep in step with the first.
    static func bands(_ day: WorkDay) -> [(band: DayBand, seconds: Double)] {
        DayBand.allCases.map { band in
            (band, band.hours.reduce(0.0) { $0 + (day.hours.indices.contains($1) ? day.hours[$1] : 0) })
        }
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


/// How much of the history a view is asking about.
enum TimeRange: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7D"
        case .month: return "30D"
        }
    }

    /// Every range is a fixed number of calendar days ending today.
    ///
    /// There was an All beside these, and it had no length of its own: it ran
    /// from the first day ever recorded, which on a new install is today. A
    /// segment whose span is "however much you happen to have" draws one bar
    /// on day one and thirty-one on day thirty-one, and never means the same
    /// thing twice. Thirty days is also all the history that is kept, so All
    /// could never have shown more than 30D does.
    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        // Thirty, which is also all the history that is kept — see
        // `WorkHistory.windowDays`, which cannot be read from here: it is
        // main-actor isolated and a range is asked for from anywhere.
        case .month: return 30
        }
    }
}

/// The parts of a day, as a person would name them.
enum DayBand: String, CaseIterable, Identifiable {
    case night, morning, afternoon, evening

    var id: String { rawValue }
    var name: String { rawValue }

    /// Four bands rather than three. Night has to be one of them: a quarter of
    /// this machine's last month fell between 22:00 and 06:00, and a card that
    /// stopped at "evening" would fold the most worrying hours available into
    /// the least alarming word available.
    var hours: Range<Int> {
        switch self {
        case .night: return 0..<6
        case .morning: return 6..<12
        case .afternoon: return 12..<18
        case .evening: return 18..<24
        }
    }

    var window: String {
        String(format: "%02d:00–%02d:00", hours.lowerBound,
               hours.upperBound == 24 ? 24 : hours.upperBound)
    }
}
