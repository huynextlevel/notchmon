import SwiftUI

/// Which page the open panel is showing.
enum NotchPage: String, CaseIterable {
    case overview, projects, time, settings
}

/// The notch's state, shared between the AppKit controller that measures the
/// screen and the SwiftUI view that draws against it.
@MainActor
final class NotchModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var isExpanded = false
    /// Clicked open, so it stays open when the pointer wanders off.
    @Published var isPinned = false
    /// Opened by a reminder rather than by the user, and therefore the app's to
    /// close again. Tracked separately from `isPinned` so a panel the user
    /// clicked into during the reminder is not taken away from under them.
    @Published var isNudged = false
    @Published var page: NotchPage = .overview

    /// What SwiftUI actually laid the current state out at.
    ///
    /// The strip is sized by its own content — that is the fix for a fixed-width
    /// bar with both sides hugging the notch and its outer ends empty — so
    /// AppKit cannot know the width by arithmetic. SwiftUI measures, publishes
    /// here, and the controller reads it back for hit-testing and hover. Without
    /// this the panel would be solid over a rectangle a different size from the
    /// one it draws, and clicks near its edge would fall through to the menu bar.
    @Published var contentSize: CGSize = .zero

    /// How far the drawn shape sits off the panel's centre so that its hole
    /// lands on the camera cutout. Zero when the two flanks match, and when the
    /// panel is open — the expanded header splits its width evenly by
    /// construction, so its hole is already centred.
    @Published var holeShift: CGFloat = 0

    /// Opacity of the alert rim, 0…1. Driven by explicit `withAnimation` from
    /// the controller rather than by an `.animation(_:value:)` modifier — an
    /// implicit animation on this subtree catches the panel's own movement, and
    /// that is what once had the refresh glyph bobbing below the header.
    @Published var alertGlow: Double = 0
    /// What colour that rim is.
    ///
    /// Nil means the quota alarm, which is red. A break reminder lends its own
    /// tone instead: red in this app means *act now*, and spending it on a
    /// suggestion to drink some water is how it stops meaning anything when it
    /// is a real one.
    @Published var alertTint: Color?

    func reportFlanks(leading: CGFloat, trailing: CGFloat) {
        let shift = StripBalance.shift(leading: leading, trailing: trailing)
        guard holeShift != shift else { return }
        holeShift = shift
    }

    /// Where the pointer is, for the views that need it.
    ///
    /// Deliberately not `@Published` on this object: it changes many times a
    /// second while the panel is open, and anything observing `NotchModel`
    /// would rebuild its whole body on every one. It is its own small object so
    /// that only the view that wants the pointer pays for it.
    let pointer = PointerTracker()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// The pointer, in panel coordinates with the origin top-left — the same space
/// SwiftUI calls `.global` inside this panel's hosting view.
///
/// SwiftUI's own `.onHover` is not usable here. This panel is a nonactivating
/// one in an accessory app, so it is never key and the app is never active, and
/// hover tracking areas are not reliably serviced in that state. The controller
/// already reads `NSEvent.mouseLocation` through a global monitor and a poll,
/// because that is the only thing that works for opening the notch at all —
/// so hover inside the panel is read from the same place rather than from a
/// second mechanism that might be asleep.
@MainActor
final class PointerTracker: ObservableObject {
    @Published private(set) var location: CGPoint?

    func update(_ point: CGPoint?) {
        // Whole points only. A tooltip cannot show sub-pixel movement, and
        // publishing it would rebuild the overlay on mouse jitter.
        let rounded = point.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
        guard rounded != location else { return }
        location = rounded
    }
}

extension View {
    /// Reports this view's laid-out size.
    ///
    /// Deliberately a callback and not a `PreferenceKey`. The canonical
    /// measurement idiom — `.background(GeometryReader { Color.clear.preference(...) })`
    /// read back with `.onPreferenceChange` — does not work: a preference set
    /// inside a `.background` never reaches the parent. It fired exactly once,
    /// with the key's default `.zero`, and never again.
    ///
    /// That single silent failure was the whole of the panel's broken
    /// interaction. AppKit hit-tests against the size reported here, so it was
    /// left holding the fallback — the bare 220x38 notch — while SwiftUI drew a
    /// 660x348 panel. Everything below the notch was outside the window's solid
    /// region, so the panel went transparent to the mouse there: tabs did
    /// nothing and the click landed on the menu bar behind them, the activity
    /// grid never saw the pointer, and moving off the notch read as leaving the
    /// panel, which closed it.
    ///
    /// The `GeometryReader` was always measuring correctly. Only the way its
    /// answer was carried out was broken.
    func measureSize(_ report: @escaping (CGSize) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.size) }
                    .onChange(of: proxy.size) { _, new in report(new) }
            }
        }
    }
}

/// One black shape that is the notch when idle and the panel when open.
///
/// Deliberately *one* shape rather than a strip plus a separate popover. When
/// the same silhouette grows, the hardware notch never stops being part of it,
/// so there is no moment where a second object appears — which is the whole
/// difference between this and an overlay parked underneath the notch.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: Preferences
    /// Sessions live here rather than being passed down, because the strip and
    /// the panel need the same list and only one of them is on screen at a time.
    @ObservedObject private var hooks = HookServer.shared
    @ObservedObject private var presence = PresenceMonitor.shared
    @ObservedObject private var nudges = NudgeCenter.shared

    /// A pill only exists while the panel is shut. Opening the panel is a
    /// louder answer to the same question, and stacking one on the other would
    /// be the app talking over itself.
    private var pill: ActiveNudge? {
        guard let up = nudges.active, up.level == .pill, !model.isExpanded else { return nil }
        return up
    }

    private var notchWidth: CGFloat { model.geometry.notchWidth }
    private var notchHeight: CGFloat { model.geometry.notchHeight }

    private var shape: NotchShape {
        NotchShape(
            topRadius: model.isExpanded ? Metrics.expandedTopRadius : Metrics.idleTopRadius,
            bottomRadius: model.isExpanded ? Metrics.expandedBottomRadius : Metrics.idleBottomRadius
        )
    }

    var body: some View {
        content
            // `.fixedSize` is what makes the strip content-sized: without it the
            // HStack would stretch to whatever the panel offers and the black
            // would run out to both ends of a 760-point window.
            .fixedSize()
            // Ground and seam are both BACKGROUND. The seam started as an
            // overlay and drew straight over the header band — tabs, gear and
            // all — because that band is exactly as tall as the black it holds.
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    shape.fill(model.isExpanded ? Palette.surface : Palette.strip)
                    seam
                }
            }
            .clipShape(shape)
            // A rim, not a fill: the strip has to stay pure black to read as
            // part of the bezel, and a wash of red across it would break the
            // one illusion the whole app rests on.
            .overlay {
                // Stroked at double width and clipped back to the silhouette,
                // which leaves the inner half. `strokeBorder` would be the
                // direct way to say that, and it needs `InsettableShape`;
                // `NotchShape` is a plain `Shape` because its flare is not an
                // inset of anything.
                shape
                    .stroke(model.alertTint ?? Palette.critical, lineWidth: 4)
                    .clipShape(shape)
                    .opacity(model.alertGlow)
                    .allowsHitTesting(false)
            }
            // Grouped before the shadow so the drop shadow follows the
            // silhouette rather than the layer's bounding box.
            .compositingGroup()
            .shadow(color: .black.opacity(model.isExpanded ? 0.55 : 0), radius: 20, y: 10)
            // Applied outside the measurement, so sliding the shape cannot feed
            // back into the widths that decide how far to slide it.
            .offset(x: model.isExpanded ? 0 : model.holeShift)
            .measureSize { size in
                // Deferred off the update pass: this feeds an `@Published` that
                // this very view observes.
                Task { @MainActor in
                    if model.contentSize != size { model.contentSize = size }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: model.isExpanded)
            // The same spring as the panel's, because it is the same gesture at
            // a smaller size: one shape, growing.
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: nudges.active)
            .animation(.easeInOut(duration: 0.22), value: model.page)
            .animation(.easeInOut(duration: 0.22), value: store.providers)
    }

    @ViewBuilder
    private var content: some View {
        if model.isExpanded {
            ExpandedView(
                model: model, store: store, preferences: preferences,
                notchHeight: notchHeight
            )
            .frame(width: Metrics.expandedWidth)
        } else if let pill {
            NudgeStripView(
                onFlanks: { leading, trailing in
                    Task { @MainActor in model.reportFlanks(leading: leading, trailing: trailing) }
                },
                nudge: pill,
                sitting: presence.clock.sitting(at: presence.now),
                notchWidth: notchWidth,
                notchHeight: notchHeight)
        } else if store.providers.isEmpty {
            IdlePlaceholder(
                onFlanks: { leading, trailing in
                    Task { @MainActor in model.reportFlanks(leading: leading, trailing: trailing) }
                },
                notchWidth: notchWidth, notchHeight: notchHeight)
        } else {
            IdleStripView(
                onFlanks: { leading, trailing in
                    Task { @MainActor in model.reportFlanks(leading: leading, trailing: trailing) }
                },
                recent: store.stripProviders,
                today: store.today,
                showing: preferences.stripRight,
                sitting: presence.clock.sitting(at: presence.now),
                baton: SessionResolve.baton(hooks.sessions),
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                isStale: store.quotaError != nil
            )
        }
    }

    /// The join between the panel's ground and the camera housing.
    ///
    /// On every theme but Obsidian the panel's surface is lifted off black, so
    /// without this it would meet the moulded black of the notch on a hard line
    /// and the welded look is gone. The first band stays pure black and fades
    /// into the surface below it.
    @ViewBuilder
    private var seam: some View {
        if model.isExpanded && Theme.current.needsSeam {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.52),
                    .init(color: .black.opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: notchHeight * 2)
            .allowsHitTesting(false)
        }
    }
}
