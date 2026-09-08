import Foundation
import ServiceManagement

/// What the strip prints on the far side of the notch.
enum StripContent: String, CaseIterable, SegmentLabelled {
    case tokens, cost, both

    var segmentLabel: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        case .both: return "Both"
        }
    }

    var showsTokens: Bool { self != .cost }
    var showsCost: Bool { self != .tokens }
}


/// What the mark does while its agent is working.
enum ActivityStyle: String, CaseIterable, SegmentLabelled {
    case notchling, bounce, off

    var segmentLabel: String {
        switch self {
        case .notchling: return "Notchling"
        case .bounce: return "Bounce"
        case .off: return "Off"
        }
    }

    var frames: [[String]]? {
        switch self {
        case .notchling: return Sprites.notchling
        case .bounce: return Sprites.bounce
        case .off: return nil
        }
    }
}

/// Everything the user can change, in one place, backed by `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    /// The panel's surface. Written straight through to `Theme.current`, which
    /// is what the palette answers from.
    @Published var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            Theme.current = theme
        }
    }

    /// Comma-separated tokscale client ids to scan. Empty means "every client
    /// this tokscale build supports", which is the useful default: the whole
    /// point is not having to enumerate fifty-odd tools by hand.
    @Published var clients: String {
        didSet { defaults.set(clients, forKey: "clients") }
    }

    /// How often the quota readings refresh. Quotas move slowly and several
    /// providers rate-limit the endpoint behind them, so this is deliberately
    /// not aggressive.
    @Published var quotaInterval: TimeInterval {
        didSet { defaults.set(quotaInterval, forKey: "quotaInterval") }
    }

    /// How often the token scan reruns. Slower still: it walks every session
    /// file on disk.
    @Published var scanInterval: TimeInterval {
        didSet { defaults.set(scanInterval, forKey: "scanInterval") }
    }

    @Published var stripRight: StripContent {
        didSet { defaults.set(stripRight.rawValue, forKey: "stripRight") }
    }

    /// Providers the user has switched off entirely. Stored as the ones hidden
    /// rather than the ones shown, so a provider you sign into later appears on
    /// its own instead of needing to be enabled.
    @Published var hiddenAgents: Set<String> {
        didSet { defaults.set(Array(hiddenAgents), forKey: "hiddenAgents") }
    }

    /// Providers held in the strip regardless of when they were last used.
    @Published var pinnedAgents: Set<String> {
        didSet { defaults.set(Array(pinnedAgents), forKey: "pinnedAgents") }
    }

    /// How much of a window has to be spent before it is worth a notification.
    @Published var warnAtPercent: Int {
        didSet { defaults.set(warnAtPercent, forKey: "warnAtPercent") }
    }

    @Published var showStatusItem: Bool {
        didSet { defaults.set(showStatusItem, forKey: "showStatusItem") }
    }

    /// A strip on every display at once.
    ///
    /// Each one is a separate window with its own state: only one can be under
    /// the pointer, so only one opens, and the others stay as strips. Where
    /// there is no camera cutout the shape is synthesized, which is how the
    /// notch reads as a tab hanging from the menu bar rather than as hardware.
    @Published var showOnAllDisplays: Bool {
        didSet { defaults.set(showOnAllDisplays, forKey: "showOnAllDisplays") }
    }

    /// With one strip, whether it follows the display being worked on.
    ///
    /// On, it moves to whichever display holds keyboard focus — the same
    /// display whose menu bar is lit. Off, it stays on the built-in display,
    /// welded to the real notch, wherever the work happens to be. Both are
    /// defensible and which one is right depends on how the desk is arranged,
    /// which is why it is a switch and not a decision made here.
    ///
    /// Ignored entirely when `showOnAllDisplays` is on: there is nothing to
    /// switch when every display already has one.
    @Published var autoSwitchDisplays: Bool {
        didSet { defaults.set(autoSwitchDisplays, forKey: "autoSwitchDisplays") }
    }

    /// What an agent's mark does while that agent is working.
    ///
    /// The strip is on screen all day, so this is the one animation in the app
    /// that had to earn its place — hence a way to turn it off that is not
    /// buried behind Reduce Motion.
    @Published var activityStyle: ActivityStyle {
        didSet { defaults.set(activityStyle.rawValue, forKey: "activityStyle") }
    }

    /// Seconds for one pass through the animation's frames.
    @Published var activityBeat: Double {
        didSet { defaults.set(activityBeat, forKey: "activityBeat") }
    }

    /// Registered with the system rather than merely remembered: the switch has
    /// to reflect what macOS actually holds, so it is read back from
    /// `SMAppService` rather than from defaults.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
                // Put the switch back where the system actually is, rather than
                // leaving it showing a state that was refused.
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "theme": Theme.ink.rawValue,
            "clients": "",
            "quotaInterval": 180.0,
            "scanInterval": 600.0,
            "stripRight": StripContent.tokens.rawValue,
            "warnAtPercent": 75,
            "showStatusItem": true,
            "activityStyle": ActivityStyle.notchling.rawValue,
            "activityBeat": 0.9,
            "showOnAllDisplays": false,
            // On by default: a strip that stays on a display you are not
            // looking at is a readout you have to turn your head to find.
            "autoSwitchDisplays": true
        ])
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .ink
        clients = defaults.string(forKey: "clients") ?? ""
        quotaInterval = defaults.double(forKey: "quotaInterval")
        scanInterval = defaults.double(forKey: "scanInterval")
        stripRight = StripContent(rawValue: defaults.string(forKey: "stripRight") ?? "") ?? .tokens
        hiddenAgents = Set(defaults.stringArray(forKey: "hiddenAgents") ?? [])
        pinnedAgents = Set(defaults.stringArray(forKey: "pinnedAgents") ?? [])
        warnAtPercent = defaults.integer(forKey: "warnAtPercent")
        showStatusItem = defaults.bool(forKey: "showStatusItem")
        activityStyle = ActivityStyle(rawValue: defaults.string(forKey: "activityStyle") ?? "") ?? .notchling
        activityBeat = defaults.double(forKey: "activityBeat")
        showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        autoSwitchDisplays = defaults.bool(forKey: "autoSwitchDisplays")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Theme.current = theme
    }

    func setAgent(_ provider: String, visible: Bool) {
        if visible {
            hiddenAgents.remove(provider)
        } else {
            hiddenAgents.insert(provider)
            // A hidden agent cannot hold a slot in the strip; leaving the pin
            // set would make it reappear the moment it was switched back on,
            // which is not what turning something off means.
            pinnedAgents.remove(provider)
        }
    }

    func togglePin(_ provider: String) {
        if pinnedAgents.contains(provider) {
            pinnedAgents.remove(provider)
        } else {
            pinnedAgents.insert(provider)
        }
    }
}
