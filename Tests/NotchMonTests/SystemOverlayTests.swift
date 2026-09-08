import CoreGraphics
import XCTest
@testable import NotchMon

/// Reading Mission Control out of the window list.
///
/// The layer is the whole decision, and the obvious choice is wrong: Mission
/// Control puts Dock windows on both 18 and 20, but the Dock's own strip also
/// lives at 20. Keying on 20 would report Mission Control permanently for
/// anyone who does not auto-hide their Dock — the notch would then never open
/// for them at all.
@MainActor
final class SystemOverlayTests: XCTestCase {
    private func window(_ owner: String, layer: Int) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer]
    }

    /// What the window server actually returns at rest, measured: the Dock owns
    /// its wallpaper windows and nothing above them.
    func testAnIdleDesktopIsNotMissionControl() {
        XCTAssertFalse(SystemOverlay.reads([
            window("Dock", layer: -2_147_483_624),
            window("Control Center", layer: 25),
            window("Window Server", layer: 24)
        ]))
    }

    /// The trap. A visible Dock is a Dock window at 20, every second of the day.
    func testAVisibleDockIsNotMissionControl() {
        XCTAssertFalse(SystemOverlay.reads([
            window("Dock", layer: -2_147_483_624),
            window("Dock", layer: 20)
        ]))
    }

    /// Measured with Mission Control up: two Dock windows at 18, three at 20.
    func testMissionControlIsRecognised() {
        XCTAssertTrue(SystemOverlay.reads([
            window("Dock", layer: -2_147_483_624),
            window("Dock", layer: 18),
            window("Dock", layer: 18),
            window("Dock", layer: 20),
            window("Window Server", layer: 24)
        ]))
    }

    /// Layer 18 only counts when the Dock is the one drawing it — another app
    /// happening to sit there says nothing about Mission Control.
    func testAnotherAppAtTheSameLayerIsNotMissionControl() {
        XCTAssertFalse(SystemOverlay.reads([window("Some Overlay", layer: 18)]))
    }

    /// An empty or unreadable list means "no overlay", never "overlay": the
    /// failure that hides the notch forever is worse than the one that lets it
    /// open over Mission Control once.
    func testAnEmptyListReadsAsNoOverlay() {
        XCTAssertFalse(SystemOverlay.reads([]))
    }
}
