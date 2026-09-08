import AppKit
import SwiftUI
import Combine

/// Owns the panel, keeps it welded to the notch, and decides when it opens.
@MainActor
final class NotchController {
    let model: NotchModel
    private let store: UsageStore
    private let preferences: Preferences

    private var panel: NotchPanel?
    private var hosting: NotchHostingView<NotchRootView>?
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    /// Short enough to feel immediate, long enough that a pointer crossing the
    /// menu bar on its way somewhere else does not drag the panel open behind it.
    private let openDelay: TimeInterval = 0.12
    /// Longer than the open delay on purpose: closing is the bigger, more
    /// distracting movement, and a panel that snaps shut whenever the pointer
    /// clips a corner reads as broken rather than responsive.
    private let closeDelay: TimeInterval = 0.35

    /// Asked for on open (rate-limited by the store) and by the menu (forced).
    var onRefresh: (() -> Void)?
    var onForceRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let panelSize = CGSize(width: Metrics.panelWidth, height: Metrics.panelHeight)

    init(store: UsageStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        let screen = NotchGeometry.preferredScreen()
        self.model = NotchModel(geometry: NotchGeometry.current(for: screen ?? NSScreen.screens[0]))
    }

    // MARK: Lifecycle

    func show() {
        buildPanelIfNeeded()
        relocate()
        startWatchingPointer()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.relocate() }
            }
            .store(in: &cancellables)

        // A Space switch is the other way the panel can lose its place: the
        // window server may re-stack it under the new Space's menu bar, or
        // — with a full-screen app on the way in or out — leave it ordered
        // out. Re-asserting frame and ordering on every switch costs one
        // setFrame and is the difference between a strip that is simply there
        // and one that reappears a beat after the desktop does.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reassert() }
            }
            .store(in: &cancellables)

        // A crossed threshold is announced in the notch itself. No system
        // notification, and so no authorisation prompt on first launch: the app
        // already owns a strip that is on screen all day, and borrowing
        // Notification Centre to say something it can say itself would be
        // asking for a permission to do worse.
        store.$warning
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] warning in
                MainActor.assumeIsolated { self?.flashAlert(warning) }
            }
            .store(in: &cancellables)

        // The shape's size depends on how many providers there are, and so do
        // the rects the panel is solid over. Losing a provider without updating
        // them would leave an invisible strip of menu bar unclickable.
        // Whatever changes the drawn size — a provider arriving, a page
        // change, a setting toggled — arrives here as one signal, because it is
        // the laid-out size the hit region has to match, not its causes.
        model.$contentSize.map { _ in () }
            .merge(with: model.$holeShift.map { _ in () })
            // Deferred by one turn on purpose. `@Published` emits from
            // `willSet`, so a sink that runs inline reads the property it was
            // notified about at its OLD value — which left the solid region
            // pinned to the launch fallback, the bare notch, for the life of
            // the process.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        openWork?.cancel()
        closeWork?.cancel()
        pollTimer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let frame = model.geometry.panelFrame(size: panelSize)
        let panel = NotchPanel(contentRect: frame)
        let root = NotchRootView(model: model, store: store, preferences: preferences)
        let hosting = NotchHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onClick = { [weak self] in self?.handleClick() }
        panel.contextMenuProvider = { [weak self] in self?.buildMenu() }
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = hosting
    }

    /// One pulse of the rim: up quickly, hold, fade. Once — the figure staying
    /// red is what carries the state afterwards, and a rim that kept blinking
    /// would be an alarm you have to dismiss rather than a thing you noticed.
    private func flashAlert(_ warning: QuotaWarning) {
        store.clearWarning()
        withAnimation(.easeOut(duration: 0.16)) { model.alertGlow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeIn(duration: 0.55)) { self?.model.alertGlow = 0 }
            }
        }
    }

    /// Puts the panel back exactly where it was and on top, after anything
    /// that might have shuffled it.
    private func reassert() {
        relocate()
        panel?.orderFrontRegardless()
    }

    /// Re-measures the notch and moves the panel onto it. Called on launch and
    /// whenever the screen layout changes — plugging in a monitor can make a
    /// notchless display the main screen, and the panel has to follow.
    func relocate() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry.current(for: screen)
        if geometry != model.geometry { model.geometry = geometry }
        panel?.setFrame(geometry.panelFrame(size: panelSize), display: true)
        updateInteractiveRects()
        Log.notch.info(
            "notch \(geometry.isHardware ? "hardware" : "synthesized", privacy: .public) \(Int(geometry.notchWidth))x\(Int(geometry.notchHeight))"
        )
    }

    // MARK: Where the panel is solid

    /// The panel is a full-width sheet over the menu bar, so by default it
    /// would swallow every click up there. It is made solid over exactly the
    /// shape currently on screen and nothing else.
    private func updateInteractiveRects() {
        hosting?.interactiveShape = currentShapePath()
    }

    /// The drawn silhouette as a path, in panel coordinates.
    ///
    /// Built from the same `NotchShape` the view draws with, at the same radii,
    /// so "where the panel is solid" and "where the panel is black" cannot drift
    /// apart.
    private func currentShapePath() -> CGPath {
        NotchShape(
            topRadius: model.isExpanded ? Metrics.expandedTopRadius : Metrics.idleTopRadius,
            bottomRadius: model.isExpanded ? Metrics.expandedBottomRadius : Metrics.idleBottomRadius
        )
        .path(in: currentShapeRect()).cgPath
    }

    /// In panel coordinates, origin top-left.
    ///
    /// Read from what SwiftUI actually laid out rather than recomputed here.
    /// The two used to be derived independently and drifted apart within about
    /// ten minutes of each other existing: the panel was then solid over a
    /// rectangle a different size from the one it drew, and clicks near the
    /// edge fell through to the menu bar.
    private func currentShapeRect() -> CGRect {
        let size = model.contentSize
        guard size.width > 0, size.height > 0 else {
            // Before the first layout, claim only the notch itself — a guess
            // that is too big would swallow menu-bar clicks, and one that is
            // too small merely misses a hover for one frame.
            return CGRect(x: (panelSize.width - model.geometry.notchWidth) / 2, y: 0,
                          width: model.geometry.notchWidth, height: model.geometry.notchHeight)
        }
        // The same slide the view draws with. If these two ever disagree the
        // panel is solid over a rectangle it did not draw, and clicks near the
        // edge fall through to the menu bar.
        let shift = model.isExpanded ? 0 : model.holeShift
        return CGRect(
            x: ((panelSize.width - size.width) / 2 + shift).rounded(),
            y: 0, width: size.width, height: size.height)
    }

    // MARK: Hover

    /// Both monitors plus a poll, because none of the three is sufficient alone:
    /// a global monitor never fires while the pointer is over our own panel, a
    /// local one never fires while it is anywhere else, and neither fires at all
    /// when the pointer arrives without moving — switching Spaces, or a window
    /// closing out from under it.
    private func startWatchingPointer() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePointer() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluatePointer() }
            return event
        }) {
            monitors.append(local)
        }
        // Dismissal. A pinned panel ignores the pointer leaving it, so the only
        // thing left that can mean "done" is a click somewhere else.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
        }) {
            monitors.append(outside)
        }
        startPolling()
    }

    /// The poll is the only thing that sees the pointer while it is over our own
    /// panel: a global monitor is deaf to events aimed at this app, and a local
    /// one never hears `.mouseMoved` in a window that is never key. Idle it only
    /// has to notice an arrival, so four times a second is plenty; open, it is
    /// also what drives hover inside the panel, and a tooltip that lagged a
    /// quarter-second behind the pointer would read as broken.
    private func startPolling() {
        pollTimer?.invalidate()
        // Open, the poll is also what feeds hover inside the panel, so it
        // runs at display rate; idle it only has to notice an arrival.
        let interval: TimeInterval = model.isExpanded ? 1.0 / 60 : 0.25
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
    }

    private func evaluatePointer() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation

        // Belt and braces over the hit-test hole. The panel is 680 points of
        // window laid across the menu bar, and a single mistake in the rect
        // maths would mean clicks on the Apple menu or a status item silently
        // going nowhere — a failure the user would blame on macOS, not on this.
        // So the window is made transparent to the mouse outright whenever the
        // pointer is not literally on the drawn shape. Hover still works: it is
        // read from `NSEvent.mouseLocation` through a global monitor, which
        // does not care whether any window accepts events.
        // Tested against the silhouette, not its bounding box, for the same
        // reason the hit region is: the flare's wedges are transparent, and a
        // window that goes opaque to the mouse over transparent pixels is a
        // window eating menu-bar clicks.
        let onShape = currentShapePath().contains(panelPoint(from: pointer))
        panel.ignoresMouseEvents = !onShape

        let frame = panel.frame
        model.pointer.update(
            onShape && model.isExpanded
                ? CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
                : nil)

        let inside = hoverTarget().contains(pointer)

        if inside {
            closeWork?.cancel()
            closeWork = nil
            guard !model.isExpanded, openWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.openWork = nil
                    guard self.hoverTarget().contains(NSEvent.mouseLocation) else { return }
                    self.setExpanded(true)
                }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: work)
        } else {
            openWork?.cancel()
            openWork = nil
            guard model.isExpanded, !model.isPinned, closeWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.closeWork = nil
                    guard !self.hoverTarget().contains(NSEvent.mouseLocation), !self.model.isPinned else { return }
                    self.setExpanded(false)
                }
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
        }
    }

    /// The region that counts as "on the notch", in screen coordinates.
    ///
    /// Collapsed, it reaches a few points below the strip: the pointer has to
    /// cross the bezel to get here, and demanding it land exactly within 38
    /// points of the top of the screen makes the notch feel like it is dodging.
    /// Expanded, the margin is larger still, because the panel has to survive
    /// the pointer travelling down it to reach a row.
    /// Exactly the drawn shape, in screen coordinates — no grace margin.
    private func shapeScreenRect() -> CGRect {
        model.geometry.screenRect(fromPanel: currentShapeRect(), panelSize: panelSize)
    }

    /// A screen point in panel coordinates, origin top-left.
    private func panelPoint(from screen: CGPoint) -> CGPoint {
        let frame = model.geometry.panelFrame(size: panelSize)
        return CGPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)
    }

    private func hoverTarget() -> CGRect {
        let rect = currentShapeRect()
        let margin: CGFloat = model.isExpanded ? 12 : 6
        let padded = CGRect(
            x: rect.minX - margin,
            y: rect.minY,
            width: rect.width + margin * 2,
            height: rect.height + margin
        )
        return model.geometry.screenRect(fromPanel: padded, panelSize: panelSize)
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded else { return }
        model.isExpanded = expanded
        if !expanded {
            model.isPinned = false
            // Closing returns to Overview. A panel that reopens on Settings
            // because that is where it was left makes the hover gesture answer
            // a question nobody asked.
            model.page = .overview
        }
        // Re-asserted on the way open as well as on a Space switch: the panel
        // shares the top of the screen with windows that come and go on their
        // own schedule, and being at the right level only settles ties with
        // windows that already existed.
        if expanded { panel?.orderFrontRegardless() }
        if !expanded {
            model.pointer.update(nil)
            // The panel can be dismissed with the pointer still over a control,
            // and that control's hover-exit never runs. Without this the
            // pointing hand would follow the user around the desktop.
            NSCursor.arrow.set()
        }
        updateInteractiveRects()
        startPolling()
        if expanded { onRefresh?() }
    }

    /// Opens the panel on a given page and keeps it there.
    func open(page: NotchPage) {
        model.page = page
        model.isPinned = true
        setExpanded(true)
    }

    /// A click inside the panel pins it open.
    ///
    /// It used to toggle the pin, which was unusable the moment the panel had
    /// controls in it: clicking "Projects" both switched the page and unpinned
    /// the panel, so the page you asked for closed as soon as the pointer left
    /// the tab. Clicking inside now only ever means "I am using this"; the way
    /// out is `dismissIfOutside`, which is how every popover on this system
    /// behaves.
    private func handleClick() {
        model.isPinned = true
        if !model.isExpanded { setExpanded(true) }
    }

    /// A click anywhere off the drawn shape closes an open panel.
    ///
    /// The pointer-based close cannot do this job on its own any more, because
    /// a pinned panel is meant to survive the pointer leaving it.
    private func dismissIfOutside() {
        guard model.isExpanded,
              !currentShapePath().contains(panelPoint(from: NSEvent.mouseLocation))
        else { return }
        setExpanded(false)
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if let updated = store.lastUpdated {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            let item = NSMenuItem(title: "Updated \(formatter.string(from: updated))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchMon", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func menuRefresh() { onForceRefresh?() }
    @objc private func menuSettings() { onOpenSettings?() }
    @objc private func menuQuit() { onQuit?() }
}
