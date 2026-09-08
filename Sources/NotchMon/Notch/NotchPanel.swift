import AppKit
import SwiftUI

/// The window the notch lives in: borderless, never takes focus, and sits above
/// the menu bar because that is the only way to reach the strips beside the notch.
final class NotchPanel: NSPanel {
    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One step above the status bar, and the step matters.
        //
        // `.statusBar` is above the main menu, which is what lets the strips
        // beside the notch be seen at all. But it is also the *exact* level
        // every status item window sits at, so ours and theirs were peers and
        // only the ordering separated them — and a menu-bar manager rebuilds
        // and reorders its items constantly. Whenever one of those landed above
        // this panel, a click meant for a control in the header went to the
        // status item underneath instead, which is why it looked like one click
        // doing two things.
        //
        // Not higher than this. Pop-up menus live at 101, and a panel above
        // those would cover the menu that drops down when you click the menu
        // bar it is sitting on.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        // `.stationary` is the flag that matters for Space switches. Without
        // it a `.canJoinAllSpaces` window rides the slide animation along with
        // the desktop — and the physical notch, being hardware, does not — so
        // for a third of a second the two visibly come apart. `.ignoresCycle`
        // keeps ⌘` from ever landing here.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // Without this the window is never sent `.mouseMoved`, so the
        // controller's local monitor is silent for exactly the span the
        // global one cannot see — the pointer inside our own panel — and
        // hover is left to a quarter-second poll.
        acceptsMouseMovedEvents = true
        // Left at the default `.readOnly` deliberately. `.none` would hide the
        // panel from screen capture entirely — and since this panel *is* the
        // notch's contents, that means screenshots and recordings of the top of
        // the screen would come back with a hole in them.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `sendEvent` sees a click before any SwiftUI view does, which is what
    /// makes it the right place to notice one — and the wrong place to consume
    /// one. This used to `return` on `.leftMouseDown`, so the notification of a
    /// click was bought by cancelling it: no button inside the panel ever
    /// received a mouse event, and the tabs and the gear were decoration that
    /// happened to highlight on hover.
    ///
    /// Now the click is reported *and* forwarded. A right click is still
    /// consumed, because a context menu is the whole response to it.
    override func sendEvent(_ event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.sendEvent(event)
        }
        switch event.type {
        case .rightMouseDown:
            if let menu = contextMenuProvider?() {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return
            }
        case .leftMouseDown:
            onClick?()
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// A hosting view that is only solid where something is drawn.
///
/// Without this the panel would be a full-width invisible sheet over the menu
/// bar, and every click on the Apple menu or a status item would land here
/// instead. The controller keeps `interactiveRects` in step with whatever the
/// notch is currently showing, and everywhere else the panel is a hole.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The silhouette actually on screen, in SwiftUI's coordinates.
    ///
    /// The shape, not its bounding box. The two differ most where it matters:
    /// the top corners flare outward, so below the first few points the drawn
    /// black is inset by the flare while the box is not. Claiming the box left
    /// the panel solid over two transparent wedges lying across the menu bar —
    /// and on this machine the right-hand wedge covers the first five points of
    /// a menu-bar utility's icon, which was therefore unclickable whenever the
    /// panel was open.
    var interactiveShape: CGPath?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveShape else { return nil }
        let local = convert(point, from: superview)
        // SwiftUI lays out from the top-left, which is how the shape is quoted,
        // so an unflipped view has to be turned over first.
        let probe = isFlipped ? local : NSPoint(x: local.x, y: bounds.height - local.y)
        guard interactiveShape.contains(probe) else { return nil }
        return super.hitTest(point)
    }
}
