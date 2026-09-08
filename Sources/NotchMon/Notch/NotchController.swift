import AppKit
import SwiftUI
import Combine

/// One display's worth of notch: the window, the view that draws it, and the
/// state the two share.
///
/// Split out when the strip learned to appear on every display at once. Each
/// display needs its own geometry (the camera cutout on one, a synthesized tab
/// on the others), its own expanded state, and its own open/close timers —
/// only one can be under the pointer, and the rest have to stay as strips
/// rather than follow it.
@MainActor
final class NotchInstance {
    let displayID: CGDirectDisplayID
    let model: NotchModel
    let panel: NotchPanel
    let hosting: NotchHostingView<NotchRootView>

    var openWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    var cancellables = Set<AnyCancellable>()

    init(displayID: CGDirectDisplayID, model: NotchModel,
         panel: NotchPanel, hosting: NotchHostingView<NotchRootView>) {
        self.displayID = displayID
        self.model = model
        self.panel = panel
        self.hosting = hosting
    }

    func cancelPending() {
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
    }
}

/// Owns the panels, keeps them welded to their notches, and decides when one
/// opens.
@MainActor
final class NotchController {
    private let store: UsageStore
    private let preferences: Preferences

    /// Keyed by display id rather than by `NSScreen`: screen objects are
    /// replaced wholesale when the layout changes, so identity has to come from
    /// the window server.
    private var instances: [CGDirectDisplayID: NotchInstance] = [:]

    /// A Space of our own, above every ordinary one, holding all the panels.
    /// Nil if the window server would not give us one, in which case the panels
    /// are ordinary windows and slide with the desktop — see `NotchSpace`.
    private var space: NotchSpace?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

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
    }

    // MARK: Lifecycle

    func show() {
        space = NotchSpace.make()
        syncDisplays()
        startWatchingPointer()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.syncDisplays() }
            }
            .store(in: &cancellables)

        // A Space switch is the other way a panel can lose its place: the
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

        // Which displays carry a strip is a setting, so changing it has to take
        // effect while the settings page is on screen — that page is drawn by
        // the very panels this rebuilds.
        preferences.$showOnAllDisplays.map { _ in () }
            .merge(with: preferences.$autoSwitchDisplays.map { _ in () })
            // `@Published` emits from `willSet`, so a sink that runs inline
            // reads the old value and rebuilds for the setting being left.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.syncDisplays() }
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

        Log.notch.info("space \(self.space == nil ? "unavailable" : "held", privacy: .public)")
    }

    func stop() {
        instances.values.forEach { $0.cancelPending() }
        pollTimer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        for instance in instances.values {
            space?.remove(instance.panel)
            instance.panel.orderOut(nil)
        }
        instances.removeAll()
        // Not optional housekeeping: a Space outlives the process that made it,
        // so quitting without this leaves an empty one at the top of the window
        // server for the rest of the login session.
        space?.destroy()
        space = nil
    }

    // MARK: Which displays carry a strip

    /// The displays that should have a notch right now, in preference order.
    private func targetScreens() -> [NSScreen] {
        if preferences.showOnAllDisplays { return NSScreen.screens }
        guard let screen = NotchGeometry.preferredScreen(
            followingFocus: preferences.autoSwitchDisplays) else { return [] }
        return [screen]
    }

    /// Brings the set of panels in line with the setting and the hardware.
    ///
    /// Idempotent, and called from four directions — launch, a display being
    /// plugged in, focus crossing to another display, and the setting itself
    /// changing — so it is written as "make it so" rather than as a diff any
    /// one caller has to compute.
    private func syncDisplays() {
        let wanted = targetScreens()
        var keep: Set<CGDirectDisplayID> = []

        for screen in wanted {
            guard let id = NotchGeometry.displayID(of: screen) else { continue }
            keep.insert(id)
            let instance = instances[id] ?? makeInstance(id: id, screen: screen)
            instances[id] = instance
            place(instance, on: screen)
        }

        for (id, instance) in instances where !keep.contains(id) {
            instance.cancelPending()
            space?.remove(instance.panel)
            instance.panel.orderOut(nil)
            instances.removeValue(forKey: id)
        }
        startPolling()
    }

    private func makeInstance(id: CGDirectDisplayID, screen: NSScreen) -> NotchInstance {
        let model = NotchModel(geometry: NotchGeometry.current(for: screen))
        let frame = model.geometry.panelFrame(size: panelSize)
        let panel = NotchPanel(contentRect: frame)
        let root = NotchRootView(model: model, store: store, preferences: preferences)
        let hosting = NotchHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let instance = NotchInstance(displayID: id, model: model, panel: panel, hosting: hosting)
        panel.onClick = { [weak self, weak instance] in
            guard let instance else { return }
            self?.handleClick(instance)
        }
        panel.contextMenuProvider = { [weak self] in self?.buildMenu() }
        panel.orderFrontRegardless()
        // Into our own Space, so a three-finger swipe does not slide the strip
        // off the camera cutout it is drawn around.
        space?.add(panel)

        // The shape's size depends on how many providers there are, and so does
        // the region the panel is solid over. Losing a provider without updating
        // it would leave an invisible strip of menu bar unclickable. Whatever
        // changes the drawn size arrives here as one signal, because it is the
        // laid-out size the hit region has to match, not its causes.
        model.$contentSize.map { _ in () }
            .merge(with: model.$holeShift.map { _ in () })
            // Deferred by one turn on purpose. `@Published` emits from
            // `willSet`, so a sink that runs inline reads the property it was
            // notified about at its OLD value — which left the solid region
            // pinned to the launch fallback, the bare notch, for the life of
            // the process.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak instance] _ in
                MainActor.assumeIsolated {
                    guard let instance else { return }
                    self?.updateInteractiveShape(instance)
                }
            }
            .store(in: &instance.cancellables)

        return instance
    }

    /// Re-measures a display's notch and moves its panel onto it.
    private func place(_ instance: NotchInstance, on screen: NSScreen) {
        let geometry = NotchGeometry.current(for: screen)
        if geometry != instance.model.geometry { instance.model.geometry = geometry }
        instance.panel.setFrame(geometry.panelFrame(size: panelSize), display: true)
        updateInteractiveShape(instance)
    }

    /// Puts every panel back where it belongs and on top, after anything that
    /// might have shuffled them.
    private func reassert() {
        syncDisplays()
        instances.values.forEach { $0.panel.orderFrontRegardless() }
    }

    /// The instance the pointer would reach first, for anything that has to
    /// pick one — a menu command, a page opened from outside.
    private var frontmost: NotchInstance? {
        if let screen = NotchGeometry.preferredScreen(followingFocus: preferences.autoSwitchDisplays),
           let id = NotchGeometry.displayID(of: screen), let instance = instances[id] {
            return instance
        }
        return instances.values.first
    }

    /// One pulse of the rim: up quickly, hold, fade. Once — the figure staying
    /// red is what carries the state afterwards, and a rim that kept blinking
    /// would be an alarm you have to dismiss rather than a thing you noticed.
    ///
    /// On every strip at once. The warning is about the account, not about a
    /// display, and a rim that flashed on one screen while you were looking at
    /// another would be a warning you can miss by sitting in the wrong chair.
    private func flashAlert(_ warning: QuotaWarning) {
        store.clearWarning()
        let models = instances.values.map(\.model)
        withAnimation(.easeOut(duration: 0.16)) { models.forEach { $0.alertGlow = 1 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                withAnimation(.easeIn(duration: 0.55)) { models.forEach { $0.alertGlow = 0 } }
            }
        }
    }

    // MARK: Where a panel is solid

    /// A panel is a full-width sheet over the menu bar, so by default it would
    /// swallow every click up there. It is made solid over exactly the shape
    /// currently on screen and nothing else.
    private func updateInteractiveShape(_ instance: NotchInstance) {
        instance.hosting.interactiveShape = shapePath(instance)
    }

    /// The drawn silhouette as a path, in panel coordinates.
    ///
    /// Built from the same `NotchShape` the view draws with, at the same radii,
    /// so "where the panel is solid" and "where the panel is black" cannot drift
    /// apart.
    private func shapePath(_ instance: NotchInstance) -> CGPath {
        let expanded = instance.model.isExpanded
        return NotchShape(
            topRadius: expanded ? Metrics.expandedTopRadius : Metrics.idleTopRadius,
            bottomRadius: expanded ? Metrics.expandedBottomRadius : Metrics.idleBottomRadius
        )
        .path(in: shapeRect(instance)).cgPath
    }

    /// In panel coordinates, origin top-left.
    ///
    /// Read from what SwiftUI actually laid out rather than recomputed here.
    /// The two used to be derived independently and drifted apart within about
    /// ten minutes of each other existing: the panel was then solid over a
    /// rectangle a different size from the one it drew, and clicks near the
    /// edge fell through to the menu bar.
    private func shapeRect(_ instance: NotchInstance) -> CGRect {
        let model = instance.model
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

    /// A screen point in one panel's coordinates, origin top-left.
    private func panelPoint(_ instance: NotchInstance, from screen: CGPoint) -> CGPoint {
        let frame = instance.model.geometry.panelFrame(size: panelSize)
        return CGPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)
    }

    /// The region that counts as "on the notch", in screen coordinates.
    ///
    /// Collapsed, it reaches a few points below the strip: the pointer has to
    /// cross the bezel to get here, and demanding it land exactly within 38
    /// points of the top of the screen makes the notch feel like it is dodging.
    /// Expanded, the margin is larger still, because the panel has to survive
    /// the pointer travelling down it to reach a row.
    private func hoverTarget(_ instance: NotchInstance) -> CGRect {
        let rect = shapeRect(instance)
        let margin: CGFloat = instance.model.isExpanded ? 12 : 6
        let padded = CGRect(
            x: rect.minX - margin,
            y: rect.minY,
            width: rect.width + margin * 2,
            height: rect.height + margin
        )
        return instance.model.geometry.screenRect(fromPanel: padded, panelSize: panelSize)
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

    /// The poll is the only thing that sees the pointer while it is over one of
    /// our own panels: a global monitor is deaf to events aimed at this app, and
    /// a local one never hears `.mouseMoved` in a window that is never key.
    /// Idle it only has to notice an arrival, so four times a second is plenty;
    /// open, it also drives hover inside the panel, and a tooltip that lagged a
    /// quarter-second behind the pointer would read as broken.
    private func startPolling() {
        pollTimer?.invalidate()
        let anyExpanded = instances.values.contains { $0.model.isExpanded }
        let interval: TimeInterval = anyExpanded ? 1.0 / 60 : 0.25
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
    }

    private func evaluatePointer() {
        guard !instances.isEmpty else { return }
        let pointer = NSEvent.mouseLocation

        // Mission Control and App Exposé are the window server's own surface,
        // and the pointer crosses the notch on its way to the space you are
        // reaching for. Expanding there turns a swipe-up into a 660-point panel
        // sitting on top of the thumbnails you are trying to pick — so the
        // notch stands down while they are up, pinned or not, and hands the
        // mouse back.
        //
        // The strip itself stays. The menu bar does not hide for Mission
        // Control and neither do its status items — both were measured still
        // on screen, at layers 24 and 25, while Mission Control drew at 18 and
        // 20 beneath them. The strip is welded to that bar; leaving with it
        // would be the inconsistency, not staying.
        if SystemOverlay.isActive {
            for instance in instances.values {
                instance.panel.ignoresMouseEvents = true
                instance.model.pointer.update(nil)
                instance.cancelPending()
                if instance.model.isExpanded {
                    instance.model.isPinned = false
                    setExpanded(false, on: instance)
                }
            }
            return
        }

        followActiveScreen()

        for instance in instances.values {
            evaluate(instance, pointer: pointer)
        }
    }

    private func evaluate(_ instance: NotchInstance, pointer: CGPoint) {
        let model = instance.model

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
        let onShape = shapePath(instance).contains(panelPoint(instance, from: pointer))
        instance.panel.ignoresMouseEvents = !onShape

        let frame = instance.panel.frame
        model.pointer.update(
            onShape && model.isExpanded
                ? CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
                : nil)

        if hoverTarget(instance).contains(pointer) {
            instance.closeWork?.cancel()
            instance.closeWork = nil
            guard !model.isExpanded, instance.openWork == nil else { return }
            let work = DispatchWorkItem { [weak self, weak instance] in
                MainActor.assumeIsolated {
                    guard let self, let instance else { return }
                    instance.openWork = nil
                    guard self.hoverTarget(instance).contains(NSEvent.mouseLocation) else { return }
                    self.setExpanded(true, on: instance)
                }
            }
            instance.openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: work)
        } else {
            instance.openWork?.cancel()
            instance.openWork = nil
            guard model.isExpanded, !model.isPinned, instance.closeWork == nil else { return }
            let work = DispatchWorkItem { [weak self, weak instance] in
                MainActor.assumeIsolated {
                    guard let self, let instance else { return }
                    instance.closeWork = nil
                    guard !self.hoverTarget(instance).contains(NSEvent.mouseLocation),
                          !instance.model.isPinned else { return }
                    self.setExpanded(false, on: instance)
                }
            }
            instance.closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
        }
    }

    /// Move with the menu bar when focus crosses to another display.
    ///
    /// There is no notification for this. `NSScreen.main` changes with keyboard
    /// focus and announces nothing, and `didChangeScreenParametersNotification`
    /// — which this also listens to — fires only when displays are added,
    /// removed or rearranged. So it is read off the pointer poll, which is
    /// already running, and compared by display id so the common case costs one
    /// set lookup.
    ///
    /// Nothing to do when every display already carries a strip.
    private func followActiveScreen() {
        guard !preferences.showOnAllDisplays, preferences.autoSwitchDisplays,
              let screen = NotchGeometry.preferredScreen(followingFocus: true),
              let id = NotchGeometry.displayID(of: screen),
              instances[id] == nil
        else { return }
        // An open panel would otherwise be left behind on a display the pointer
        // is not on, expanded, with nothing to close it.
        for instance in instances.values where instance.model.isExpanded {
            instance.model.isPinned = false
            setExpanded(false, on: instance)
        }
        syncDisplays()
        instances.values.forEach { $0.panel.orderFrontRegardless() }
    }

    private func setExpanded(_ expanded: Bool, on instance: NotchInstance) {
        let model = instance.model
        guard model.isExpanded != expanded else { return }
        model.isExpanded = expanded
        if !expanded {
            model.isPinned = false
            // Closing returns to Overview. A panel that reopens on Settings
            // because that is where it was left makes the hover gesture answer
            // a question nobody asked.
            model.page = .overview
            model.pointer.update(nil)
            // The panel can be dismissed with the pointer still over a control,
            // and that control's hover-exit never runs. Without this the
            // pointing hand would follow the user around the desktop.
            NSCursor.arrow.set()
        } else {
            // Re-asserted on the way open as well as on a Space switch: the
            // panel shares the top of the screen with windows that come and go
            // on their own schedule, and being at the right level only settles
            // ties with windows that already existed.
            instance.panel.orderFrontRegardless()
        }
        updateInteractiveShape(instance)
        startPolling()
        if expanded { onRefresh?() }
    }

    /// Opens the panel on a given page and keeps it there.
    func open(page: NotchPage) {
        guard let instance = frontmost else { return }
        instance.model.page = page
        instance.model.isPinned = true
        setExpanded(true, on: instance)
    }

    /// A click inside a panel pins it open.
    ///
    /// It used to toggle the pin, which was unusable the moment the panel had
    /// controls in it: clicking "Projects" both switched the page and unpinned
    /// the panel, so the page you asked for closed as soon as the pointer left
    /// the tab. Clicking inside now only ever means "I am using this"; the way
    /// out is `dismissIfOutside`, which is how every popover on this system
    /// behaves.
    private func handleClick(_ instance: NotchInstance) {
        instance.model.isPinned = true
        if !instance.model.isExpanded { setExpanded(true, on: instance) }
    }

    /// A click anywhere off the drawn shape closes an open panel.
    ///
    /// The pointer-based close cannot do this job on its own any more, because
    /// a pinned panel is meant to survive the pointer leaving it.
    private func dismissIfOutside() {
        let pointer = NSEvent.mouseLocation
        for instance in instances.values where instance.model.isExpanded {
            guard !shapePath(instance).contains(panelPoint(instance, from: pointer)) else { continue }
            setExpanded(false, on: instance)
        }
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
