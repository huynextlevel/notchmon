import AppKit
import CoreGraphics
import Foundation

/// Which displays currently have a full-screen Space in front.
///
/// **Why this is not a public API question.** AppKit tells an app about its own
/// full-screen windows and nothing about anyone else's. The window list does not
/// answer it either: a full-screen app's window was on screen in only one sample
/// out of eighteen while the app sat in full screen the whole time. And the
/// obvious public proxy — the menu bar hiding, so `visibleFrame.maxY` meets
/// `frame.maxY` — never moved at all: measured at a 39-point gap in every sample,
/// full screen or not.
///
/// What does answer it is `CGSCopyManagedDisplaySpaces`, which returns the
/// window server's own per-display record. Per-display is the point: a browser
/// taken full screen on an external monitor must not blank the strip on the
/// built-in one, and a global "is anything full screen" check gets that wrong.
///
/// **Two signals, because they cost nothing together.** The active space carries
/// `type` 4 when it is a full-screen space, and the same space carries a
/// `TileLayoutManager` — which is what boring.notch reads, through its own
/// MacroVisionKit. Measured across an enter/exit cycle on both displays the two
/// agreed on every sample. Accepting either means a macOS release that changes
/// one of them does not take the feature with it.
///
/// `dlsym` rather than `@_silgen_name` — which is what MacroVisionKit uses — for
/// the reason `NotchSpace` gives: a name that binds at load time stops the app
/// launching if it ever disappears, and this is a nicety, not a reason to fail
/// to start.
@MainActor
enum FullScreenSpace {
    /// Long enough that the cost is nothing on a 4 Hz idle poll, short enough
    /// that the strip is back before the desktop finishes sliding in.
    private static let ttl: TimeInterval = 0.2
    private static var asked = Date.distantPast
    private static var covered: Set<String> = []

    static func covers(_ displayID: CGDirectDisplayID) -> Bool {
        guard let uuid = uuid(of: displayID) else { return false }
        return current().contains(uuid)
    }

    private static func current() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(asked) < ttl { return covered }
        asked = now
        covered = API.shared.flatMap { api in
            (api.copySpaces(api.connection) as? [[String: Any]]).map(reads)
        } ?? []
        return covered
    }

    /// Split from the call so the reading can be tested. A test cannot put the
    /// window server into full screen, but the shape of the dictionary is
    /// exactly where a mistake would live.
    static func reads(_ displays: [[String: Any]]) -> Set<String> {
        var out: Set<String> = []
        for display in displays {
            guard let id = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any]
            else { continue }

            let isFullScreenType = (current["type"] as? Int) == fullScreenType

            // The Current Space entry is a summary; the tile layout lives on the
            // matching entry in the display's own space list.
            let managed = current["ManagedSpaceID"] as? Int
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            let active = spaces.first { ($0["ManagedSpaceID"] as? Int) == managed }
            let isTiled = active?["TileLayoutManager"] != nil

            if isFullScreenType || isTiled { out.insert(id) }
        }
        return out
    }

    private static let fullScreenType = 4

    private static func uuid(of displayID: CGDirectDisplayID) -> String? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, ref.takeRetainedValue()) as String
    }

    private struct API {
        typealias Connection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> CFArray?

        let connection: Int32
        let copySpaces: CopySpaces

        static let shared: API? = {
            func symbol(_ name: String) -> UnsafeMutableRawPointer? {
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            }
            guard let c = symbol("_CGSDefaultConnection"),
                  let s = symbol("CGSCopyManagedDisplaySpaces")
            else {
                Log.notch.info("full-screen detection unavailable: CGS symbols missing")
                return nil
            }
            return API(connection: unsafeBitCast(c, to: Connection.self)(),
                       copySpaces: unsafeBitCast(s, to: CopySpaces.self))
        }()
    }
}
