import AppKit
import Combine
import Sparkle

/// Software updates, over Sparkle.
///
/// The one dependency in the app. Everything else here is hand-rolled, and that
/// instinct is right when what you are replacing is a *procedure*. An updater is
/// not one: it verifies a signature, downloads, and replaces the running binary.
/// Getting that wrong does not produce a bad layout, it produces a channel for
/// installing arbitrary software on someone's Mac.
///
/// Sparkle already stores both switches in `UserDefaults` and owns the schedule,
/// so none of it is mirrored into `Preferences`. Two stores for one fact drift,
/// and the copy that loses is always the one the updater actually reads.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var watch: NSKeyValueObservation?

    /// Set from the updater on start, and written back to it on change. The
    /// guard stops the two from bouncing off each other.
    @Published var checksAutomatically = true {
        didSet {
            guard let u = updater, u.automaticallyChecksForUpdates != checksAutomatically else { return }
            u.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    @Published var downloadsAutomatically = false {
        didSet {
            guard let u = updater, u.automaticallyDownloadsUpdates != downloadsAutomatically else { return }
            u.automaticallyDownloadsUpdates = downloadsAutomatically
        }
    }

    @Published private(set) var lastChecked: Date?

    /// False while a check is already running, so the button cannot start a
    /// second one on top of the first.
    @Published private(set) var idle = true

    private override init() { super.init() }

    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c

        checksAutomatically = c.updater.automaticallyChecksForUpdates
        downloadsAutomatically = c.updater.automaticallyDownloadsUpdates
        lastChecked = c.updater.lastUpdateCheckDate

        // The date only moves when a check finishes, and a check finishing is
        // exactly when this flips back to true — so one observation keeps both
        // the button and the timestamp honest without a polling timer.
        watch = c.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            MainActor.assumeIsolated {
                self?.idle = u.canCheckForUpdates
                self?.lastChecked = u.lastUpdateCheckDate
            }
        }
        Log.app.info("updates: automatic=\(c.updater.automaticallyChecksForUpdates, privacy: .public)")
    }

    func checkNow() {
        updater?.checkForUpdates()
    }

    /// "Never" rather than an empty space: the absence of a date is a fact about
    /// the app, and a blank reads as a layout bug.
    var lastCheckedLabel: String {
        guard let lastChecked else { return "never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "checked \(f.localizedString(for: lastChecked, relativeTo: Date()))"
    }
}

// MARK: - Bringing the app forward

/// An accessory app is never the frontmost application, so every window Sparkle
/// opens — the update sheet, the error alert — is put up behind whatever the
/// person is actually looking at. It reads as "the button did nothing", which is
/// the symptom filed against Sparkle for menu-bar apps often enough to look like
/// a framework bug. It is not: the app simply has to activate itself first.
extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
