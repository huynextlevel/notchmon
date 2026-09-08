import CoreGraphics
import Foundation

/// Whether one of the window server's own full-screen surfaces — Mission
/// Control, App Exposé — is on screen.
///
/// There is no public notification for this, and the private SkyLight calls
/// that would answer it directly are not worth shipping in an app that has
/// nothing else to hide. What *is* public is the window list, and Mission
/// Control leaves an unambiguous mark in it: the Dock process, which draws it,
/// puts windows on **layer 18** — and nothing else on this system does.
///
/// Layer 20 is the obvious candidate and it is wrong. The Dock's own strip
/// lives at 20, so a check on 20 reports Mission Control permanently for
/// anyone who does not auto-hide their Dock. This was measured rather than
/// assumed: at rest the Dock owns two windows, both on the wallpaper layer,
/// and its strip at 20 off screen; with Mission Control up it owns two more at
/// 18 and three at 20.
@MainActor
enum SystemOverlay {
    /// Measured, not documented, so it is named where it can be found again.
    private static let exposeLayer = 18

    /// The answer costs a round trip to the window server, and the pointer poll
    /// runs at display rate while the panel is open. A tenth of a second is far
    /// under the time it takes anyone to see a panel appear and far over the
    /// cost of asking.
    private static let ttl: TimeInterval = 0.1
    private static var asked = Date.distantPast
    private static var answer = false

    static var isActive: Bool {
        let now = Date()
        if now.timeIntervalSince(asked) < ttl { return answer }
        asked = now
        answer = ask()
        return answer
    }

    private static func ask() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return reads(windows)
    }

    /// Split from the query so the layer decision can be tested. The window
    /// server cannot be put into Mission Control from a test, but the reading
    /// of what it returns is where the mistake would be.
    static func reads(_ windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            window[kCGWindowOwnerName as String] as? String == "Dock"
                && window[kCGWindowLayer as String] as? Int == exposeLayer
        }
    }
}
