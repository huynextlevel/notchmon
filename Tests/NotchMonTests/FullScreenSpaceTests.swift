import XCTest
@testable import NotchMon

/// Reading the window server's per-display Space record.
///
/// A test cannot put a display into full screen, so what is pinned here is the
/// reading: which key means what, and — the part that would be easy to get
/// wrong and hard to notice — that the answer is per display rather than one
/// verdict for the machine.
@MainActor
final class FullScreenSpaceTests: XCTestCase {
    private let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private let external = "8921FC96-539B-4CB8-9529-1C410D46BB1B"

    private func display(_ id: String, type: Int, managed: Int = 1,
                         spaces: [[String: Any]]? = nil) -> [String: Any] {
        [
            "Display Identifier": id,
            "Current Space": ["ManagedSpaceID": managed, "type": type],
            "Spaces": spaces ?? [["ManagedSpaceID": managed, "type": type]]
        ]
    }

    func testANormalDesktopIsNotFullScreen() {
        XCTAssertEqual(FullScreenSpace.reads([display(builtIn, type: 0)]), [])
    }

    /// The shape measured while a browser sat in full screen on the built-in
    /// display: type 4 on that display, 0 on the other.
    func testSpaceTypeFourIsFullScreen() {
        XCTAssertEqual(FullScreenSpace.reads([display(builtIn, type: 4)]), [builtIn])
    }

    /// The bug this rules out: one display going full screen must not blank the
    /// strip on a display that did not.
    func testOnlyTheDisplayThatWentFullScreenIsReported() {
        let displays = [display(builtIn, type: 0), display(external, type: 4)]
        XCTAssertEqual(FullScreenSpace.reads(displays), [external])
    }

    /// boring.notch's signal, accepted alongside the type so that a macOS
    /// release changing one of them does not take the feature with it.
    func testATileLayoutCountsEvenWhereTheTypeDoesNot() {
        let spaces: [[String: Any]] = [["ManagedSpaceID": 7, "TileLayoutManager": ["TileSpaces": []]]]
        let displays = [display(builtIn, type: 0, managed: 7, spaces: spaces)]
        XCTAssertEqual(FullScreenSpace.reads(displays), [builtIn])
    }

    /// The tile layout has to be looked up on the ACTIVE space. A full-screen
    /// Space sitting behind the desktop you are looking at is not covering
    /// anything, and reporting it would hide the strip permanently for anyone
    /// who keeps one around.
    func testATileLayoutOnAnInactiveSpaceIsIgnored() {
        let spaces: [[String: Any]] = [
            ["ManagedSpaceID": 1, "type": 0],
            ["ManagedSpaceID": 9, "TileLayoutManager": ["TileSpaces": []]]
        ]
        let displays = [display(builtIn, type: 0, managed: 1, spaces: spaces)]
        XCTAssertEqual(FullScreenSpace.reads(displays), [])
    }

    /// Missing keys are a window server that changed shape, not a full screen.
    /// Guessing "covered" there would hide the app with no way to get it back.
    func testAnUnreadableEntryIsNotTreatedAsFullScreen() {
        XCTAssertEqual(FullScreenSpace.reads([["Display Identifier": builtIn]]), [])
        XCTAssertEqual(FullScreenSpace.reads([[:]]), [])
    }
}
