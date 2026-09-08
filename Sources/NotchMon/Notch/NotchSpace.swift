import AppKit

/// A window-server Space of our own, so the strip does not slide with the
/// desktop.
///
/// **Why this exists.** `.stationary` in the panel's collection behaviour is
/// documented to keep a window out of the Space transition, and on macOS 26 it
/// does not. Measured during a three-finger swipe: the panel's frame never
/// moves and its alpha never changes, yet the strip visibly slides while the
/// camera cutout — being hardware — does not, so for a third of a second the
/// two come apart. The displacement is done by the window server compositing
/// the transition, which means there is nothing in AppKit holding the position
/// to correct, and no notification fires *before* a swipe to hide the strip
/// behind. Every public avenue is closed.
///
/// The one mechanism that works is to create a Space at an absolute level above
/// all the ordinary ones and move the panel into it. A window there is outside
/// the Spaces machinery, so there is no transition for it to ride.
///
/// **Why `dlsym` and not `@_silgen_name`.** These symbols are private to
/// CoreGraphics. `@_silgen_name` binds them at load time, so the day Apple
/// removes one the app stops launching — the worst possible failure for a thing
/// whose job is to be quietly present. Looked up by hand, a missing symbol
/// means `make` returns nil and the caller keeps its plain panel: a strip that
/// slides for a third of a second during a swipe, which is exactly what it does
/// today. The degradation is back to the status quo, not to a dead app.
///
/// Written from the published descriptions of these calls rather than copied:
/// the widely circulated implementation is MPL-licensed, and every other
/// dependency here is MIT.
@MainActor
final class NotchSpace {
    /// Above every ordinary Space. The same level the other notch apps use, and
    /// for the same reason — anything lower and a full-screen Space still wins.
    nonisolated static let aboveEverything: Int32 = .max

    private let connection: Int32
    private let identifier: UInt64
    private let api: API
    private var members: Set<Int> = []

    /// Nil when any one symbol is missing, which is the whole point of asking
    /// for them by name.
    static func make(level: Int32 = aboveEverything) -> NotchSpace? {
        guard let api = API() else {
            Log.notch.info("window-server Space unavailable; strip will ride Space transitions")
            return nil
        }
        let connection = api.defaultConnection()
        // Flag 1, not 0. At 0 the Finder decides this Space is a desktop and
        // draws icons on it — a documented quirk of this call, and the sort of
        // thing that only shows up as "why is there a Macintosh HD icon on top
        // of everything".
        let identifier = api.createSpace(connection, 1, nil)
        guard identifier != 0 else {
            Log.notch.error("window-server refused a Space; strip will ride Space transitions")
            return nil
        }
        api.setAbsoluteLevel(connection, identifier, level)
        api.showSpaces(connection, [identifier] as CFArray)
        Log.notch.info("window-server Space \(identifier, privacy: .public) at level \(level, privacy: .public)")
        return NotchSpace(connection: connection, identifier: identifier, api: api)
    }

    private init(connection: Int32, identifier: UInt64, api: API) {
        self.connection = connection
        self.identifier = identifier
        self.api = api
    }

    func add(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0, members.insert(number).inserted else { return }
        api.addWindows(connection, [number] as CFArray, [identifier] as CFArray)
    }

    func remove(_ window: NSWindow) {
        let number = window.windowNumber
        guard members.remove(number) != nil else { return }
        api.removeWindows(connection, [number] as CFArray, [identifier] as CFArray)
    }

    /// A Space outlives the process that made it unless it is destroyed, so
    /// this is not optional housekeeping: quitting without it leaves an empty
    /// Space at the top of the window server for the rest of the login session.
    func destroy() {
        if !members.isEmpty {
            api.removeWindows(connection, members.map { $0 } as CFArray, [identifier] as CFArray)
            members.removeAll()
        }
        api.hideSpaces(connection, [identifier] as CFArray)
        api.destroySpace(connection, identifier)
    }

    /// The eight calls, resolved once. `CGSConnectionID` is an `int` and
    /// `CGSSpaceID` a `uint64_t`; getting either width wrong hands the window
    /// server a garbage argument, so they are spelled exactly.
    private struct API {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias CreateSpace = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
        typealias SetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
        typealias DestroySpace = @convention(c) (Int32, UInt64) -> Void
        typealias SpacesCall = @convention(c) (Int32, CFArray) -> Void
        typealias WindowsCall = @convention(c) (Int32, CFArray, CFArray) -> Void

        let defaultConnection: DefaultConnection
        let createSpace: CreateSpace
        let setAbsoluteLevel: SetAbsoluteLevel
        let destroySpace: DestroySpace
        let showSpaces: SpacesCall
        let hideSpaces: SpacesCall
        let addWindows: WindowsCall
        let removeWindows: WindowsCall

        init?() {
            // CoreGraphics is already in the process, so the default search
            // order finds these without opening anything.
            func symbol(_ name: String) -> UnsafeMutableRawPointer? {
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            }
            guard let connection = symbol("_CGSDefaultConnection") ?? symbol("CGSMainConnectionID"),
                  let create = symbol("CGSSpaceCreate"),
                  let level = symbol("CGSSpaceSetAbsoluteLevel"),
                  let destroy = symbol("CGSSpaceDestroy"),
                  let show = symbol("CGSShowSpaces"),
                  let hide = symbol("CGSHideSpaces"),
                  let add = symbol("CGSAddWindowsToSpaces"),
                  let subtract = symbol("CGSRemoveWindowsFromSpaces")
            else { return nil }
            defaultConnection = unsafeBitCast(connection, to: DefaultConnection.self)
            createSpace = unsafeBitCast(create, to: CreateSpace.self)
            setAbsoluteLevel = unsafeBitCast(level, to: SetAbsoluteLevel.self)
            destroySpace = unsafeBitCast(destroy, to: DestroySpace.self)
            showSpaces = unsafeBitCast(show, to: SpacesCall.self)
            hideSpaces = unsafeBitCast(hide, to: SpacesCall.self)
            addWindows = unsafeBitCast(add, to: WindowsCall.self)
            removeWindows = unsafeBitCast(subtract, to: WindowsCall.self)
        }
    }
}
