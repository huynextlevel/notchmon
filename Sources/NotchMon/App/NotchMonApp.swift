import AppKit

/// `@main` on a type rather than top-level code in `main.swift`: top-level code
/// is nonisolated, and everything this app owns — the panel, the store, the
/// delegate — is main-actor bound.
@main
@MainActor
enum NotchMonApp {
    /// Held here because `NSApplication.delegate` is a weak reference; a
    /// delegate that only exists as a local would be gone before the first
    /// event arrived.
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        // Accessory, not regular: the notch is the interface, and a Dock icon
        // plus a menu of its own would be two more pieces of chrome for
        // something whose whole point is to already be on screen.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
