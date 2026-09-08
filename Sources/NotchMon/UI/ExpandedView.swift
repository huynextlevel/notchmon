import SwiftUI

/// The panel the notch grows into.
///
/// **Nothing interactive is placed in the first `notchHeight` points.** That
/// band is level with the camera housing, which means it is also, in screen
/// coordinates, the menu bar — and menu-bar utilities watch the menu bar with a
/// system-wide event tap. A tap sees a click wherever it lands, so this panel
/// consuming the event does not hide it: with Ice's "show hidden items on
/// click" enabled, every press on a tab up there also revealed Ice's hidden
/// section. The click was reaching this panel correctly the whole time; the
/// mistake was asking for a click in a strip the rest of the system treats as
/// its own.
///
/// So the band is left as plain black — which is what makes the panel read as
/// an extension of the hardware anyway — and the controls sit on their own row
/// below it. That row is a better row: with no hole to steer around it has the
/// full width, instead of the 220 points a side that made the tabs truncate.
struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: Preferences
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)

            PanelHeader(
                page: $model.page,
                isRefreshing: store.isRefreshing,
                onRefresh: { store.refresh(force: true) }
            )
            .padding(.horizontal, Metrics.contentInset)

            page
                .padding(.horizontal, Metrics.contentInset)
                .padding(.bottom, Metrics.bottomInset)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .overview: OverviewPage(store: store, pointer: model.pointer)
        case .projects: ProjectsPage(store: store)
        case .settings: SettingsPage(store: store, preferences: preferences)
        }
    }
}

/// Navigation on the left, actions on the right, on one full-width row.
///
/// The day's token total used to live on the right of this band. It left: it is
/// the hero of the page directly below, and printing it twice on one panel
/// spent the scarcest row in the app on a repeat.
struct PanelHeader: View {
    @Binding var page: NotchPage
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tab(.overview, Symbol.overview, "Overview")
            tab(.projects, Symbol.projects, "Projects")

            Spacer(minLength: 12)

            Button(action: onRefresh) {
                // The system's own indeterminate indicator while a fetch is
                // out, in the same 25-point slot the glyph occupies, so the row
                // does not reflow when it swaps. Hand-rolling the rotation is
                // what put a `.repeatForever` animation on a view inside a
                // panel that moves — see the note this replaces.
                if isRefreshing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Palette.secondaryText)
                } else {
                    Image(systemName: Symbol.refresh)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(IconButtonStyle(isSelected: false))
            .disabled(isRefreshing)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")

            // The gear is both the control and its own tab indicator: settings
            // is a destination like the other two, so it lights up the same way
            // rather than opening a second surface to manage.
            Button { page = .settings } label: {
                Image(systemName: Symbol.settings)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(isSelected: page == .settings))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .frame(height: Metrics.controlRow)
    }

    private func tab(_ destination: NotchPage, _ symbol: String, _ title: String) -> some View {
        Button { page = destination } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(Typeface.label(11.5, weight: page == destination ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(TabButtonStyle(isSelected: page == destination))
        .accessibilityAddTraits(page == destination ? [.isSelected] : [])
    }
}

// MARK: - Controls

struct TabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, isSelected: isSelected, width: nil)
    }
}

struct IconButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, isSelected: isSelected, width: 25)
    }
}

/// An outlined button: a border around an icon and a word.
///
/// The border is the point. Every other control on this panel is a bare glyph
/// or a pill that only fills once the pointer is on it, which is right for
/// things you reach for constantly and wrong for the one control that ends the
/// session — an action nobody should arrive at by accident has to look like a
/// thing you deliberately press, at rest and not only under the pointer.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Not named `Body`: that is `ButtonStyle`'s own associated type, and a
        // nested type of that name is read as the witness for it.
        Outlined(configuration: configuration)
    }

    private struct Outlined: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Palette.primaryText : Palette.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    shape.fill(configuration.isPressed ? Palette.activeFill
                               : (hovering ? Palette.hover : .clear))
                }
                .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
                .contentShape(Rectangle())
                .clickable()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

/// The shared body of both header controls: same corner, same fills, same
/// hover. Split out as a `View` rather than written inline in `makeBody`
/// because it needs `@State` for the hover, which a `ButtonStyle` cannot hold.
private struct Pill: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let width: CGFloat?

    @State private var hovering = false

    private var fill: Color {
        if isSelected { return Palette.activeFill }
        if configuration.isPressed { return Palette.activeFill }
        return hovering ? Palette.hover : .clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isSelected || hovering ? Palette.primaryText : Palette.secondaryText)
            .padding(.horizontal, width == nil ? 8 : 0)
            .frame(width: width, height: 25)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            }
            .contentShape(Rectangle())
            .clickable()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// A section heading. Uppercase and tracked, because at nine points a lowercase
/// label of this weight reads as body text rather than as a divider.
struct Eyebrow: View {
    let text: String
    var tone: Color?

    init(_ text: String, tone: Color? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(Typeface.label(9.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.9)
            .foregroundStyle(tone ?? Palette.faintText)
    }
}

/// A titled band with an optional figure on the right.
struct Section<Content: View>: View {
    let title: String
    var aside: String?
    var isFirst = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // An untitled section draws no heading row at all. It used to draw
            // an empty `Eyebrow`, which is invisible and still a full line of
            // type plus the stack's spacing — about twenty points of nothing
            // between the header rule and the hero.
            if !title.isEmpty || aside != nil {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(title)
                    Spacer(minLength: 12)
                    if let aside { Eyebrow(aside) }
                }
            }
            content
        }
        .padding(.top, Metrics.sectionGap)
        // Matched to the top, so the rule that opens the next section sits
        // midway between the two rather than resting on this one's last line.
        .padding(.bottom, Metrics.sectionGap)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
        }
    }
}
