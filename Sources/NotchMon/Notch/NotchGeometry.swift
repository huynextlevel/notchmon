import AppKit

/// Where the hardware notch actually is, and the panel that has to line up with it.
///
/// The one thing worth being blunt about: **the notch has no pixels.** It is a
/// hole in the panel for the camera, not a dark region of screen. Nothing can be
/// drawn *inside* it. What can be done — and what makes an overlay read as part
/// of the notch rather than parked under it — is to own the two menu-bar strips
/// either side of it and to grow a pure-black shape out of it, so the eye joins
/// the hole and the shape into one object.
struct NotchGeometry: Equatable {
    /// The full display, `frame` not `visibleFrame`: the panel deliberately
    /// covers the menu bar, because that is where the notch is.
    let screenFrame: CGRect
    /// The camera housing, in screen coordinates (AppKit, y up).
    let notchRect: CGRect
    /// True when `notchRect` came from the hardware rather than being made up
    /// for a display that has no notch.
    let isHardware: Bool

    var notchWidth: CGFloat { notchRect.width }
    var notchHeight: CGFloat { notchRect.height }

    // MARK: Reading it off a screen

    /// AppKit never reports the notch directly — it reports the two menu-bar
    /// strips left and right of it, and the height of the unsafe band above the
    /// content area. The notch is what is left in between.
    static func hardwareNotch(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        let frame = screen.frame
        let width = frame.width - left.width - right.width
        let height = screen.safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return CGRect(
            x: frame.minX + left.width,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// A display with no notch still gets one, sized like a 14-inch MacBook
    /// Pro's. Refusing to run there would mean the app vanishing the moment an
    /// external monitor became the main screen, which is worse than a notch
    /// that is merely drawn rather than moulded.
    static func synthesized(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let width: CGFloat = 220
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    static func current(for screen: NSScreen) -> NotchGeometry {
        if let notch = hardwareNotch(of: screen) {
            return NotchGeometry(screenFrame: screen.frame, notchRect: notch, isHardware: true)
        }
        return NotchGeometry(
            screenFrame: screen.frame,
            notchRect: synthesized(for: screen),
            isHardware: false
        )
    }

    /// The display whose menu bar is live.
    ///
    /// This used to pin to the built-in display and never leave, on the
    /// argument that the hardware notch is the only thing this app has to weld
    /// itself to, and that following focus would draw a made-up notch on a
    /// monitor which has none while the real one sat empty. The argument is
    /// sound and it is still the wrong behaviour: on a two-display desk the
    /// strip has to be on the display being worked on, or it is a readout you
    /// have to turn your head to find.
    ///
    /// `NSScreen.main` is the display holding **keyboard focus**. Measured, it
    /// does not follow the pointer — the strip therefore moves when work moves,
    /// not when the mouse wanders across a bezel, which is the difference
    /// between following and twitching.
    ///
    /// Every display carries its own menu bar under "Displays have separate
    /// Spaces" (two `Menubar` windows were counted on this desk), so there is
    /// always a bar for the strip to sit in; where there is no hardware notch
    /// the shape is synthesized.
    static func preferredScreen() -> NSScreen? {
        NSScreen.main
            ?? NSScreen.screens.first(where: { hardwareNotch(of: $0) != nil })
            ?? NSScreen.screens.first
    }

    // MARK: The panel

    /// The panel is a fixed rectangle big enough for the widest state, and the
    /// shape inside it is what animates.
    ///
    /// Resizing the window on every hover was the alternative, and it looks
    /// wrong: AppKit resizes on its own clock, so the black shape and its frame
    /// arrive a frame or two apart and the panel visibly snaps. A window that
    /// never moves cannot snap.
    func panelFrame(size: CGSize) -> CGRect {
        CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: (screenFrame.maxY - size.height).rounded(),
            width: size.width.rounded(.up),
            height: size.height.rounded(.up)
        )
    }

    /// Where the notch sits inside the panel, in SwiftUI's coordinates
    /// (origin top-left, y growing downward).
    func notchRectInPanel(panelSize: CGSize) -> CGRect {
        CGRect(
            x: (panelSize.width - notchWidth) / 2,
            y: 0,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// A rect given in panel coordinates, converted back to the screen so the
    /// hover monitor can test `NSEvent.mouseLocation` against it directly.
    func screenRect(fromPanel rect: CGRect, panelSize: CGSize) -> CGRect {
        let panel = panelFrame(size: panelSize)
        return CGRect(
            x: panel.minX + rect.minX,
            y: panel.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
