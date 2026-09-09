import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let preferences = Preferences.shared
    private lazy var controller = NotchController(store: store, preferences: preferences)
    private var statusItem: NSStatusItem?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onRefresh = { [weak self] in self?.store.refresh() }
        controller.onForceRefresh = { [weak self] in self?.store.refresh(force: true) }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onQuit = { NSApp.terminate(nil) }

        handleTerminationSignal()
        controller.show()
        store.start()
        AgentActivity.shared.start()
        installStatusItem()

        // Development affordance: open straight onto a page, so a screenshot
        // does not need clicks landing on whatever the user is actually doing.
        if let name = ProcessInfo.processInfo.environment["NOTCHMON_OPEN_PAGE"],
           let page = NotchPage(rawValue: name) {
            controller.open(page: page)
        }

        HookServer.shared.start()
        PresenceMonitor.shared.start()
        Updates.shared.start()
        Log.app.info("notchmon up")
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        controller.stop()
        AgentActivity.shared.stop()
        HookServer.shared.stop()
        PresenceMonitor.shared.stop()
    }

    /// Quit cleanly on SIGTERM as well as on the menu.
    ///
    /// The app now holds a window-server Space, and a Space outlives the
    /// process that made it — so an exit that skips `applicationWillTerminate`
    /// leaves one behind for the rest of the login session. AppKit installs no
    /// handler for SIGTERM, which means `killall`, a crash reporter's kill, and
    /// anything else that is not the Quit menu would leak one every time.
    ///
    /// A dispatch source rather than `signal()`: a C signal handler may not
    /// touch AppKit, and this one has to run the ordinary termination path.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    /// A menu-bar item as well as the notch, because a notch that has not
    /// loaded yet is invisible by design — without this there would be no way
    /// to reach settings or quit if the first refresh failed.
    /// The menu-bar mark: the app's own notch silhouette, same geometry as the
    /// app icon.
    ///
    /// Drawn from `NotchShape` rather than shipped as an asset, for two
    /// reasons. A menu-bar image has to be a **template** — a flat silhouette
    /// the system tints itself, so it works on a light menu bar, a dark one and
    /// under Reduce Transparency — which rules out reusing the icon file, since
    /// that is a full-colour tile with a background. And drawing it from the
    /// same `Shape` the panel draws means the two cannot drift apart.
    ///
    /// The flare is opened up relative to the app icon: at eighteen points the
    /// icon's proportion leaves it about two points wide, which survives on a
    /// Retina display and disappears on anything else.
    private static func trayMark(height: CGFloat = 17) -> NSImage {
        let width = (height * 1.03).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let path = NotchShape(topRadius: rect.width * 0.14,
                                  bottomRadius: rect.width * 0.24).path(in: rect)
            context.addPath(path.cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        // Template, so the system owns the colour: black here is a stencil, not
        // a choice about how it looks.
        image.isTemplate = true
        image.accessibilityDescription = "NotchMon"
        return image
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.trayMark()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchMon", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func refresh() { store.refresh(force: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Settings lives in the notch now, so "Settings…" opens the notch on that
    /// page rather than a window of its own.
    @objc private func openSettings() {
        controller.open(page: .settings)
    }
}
