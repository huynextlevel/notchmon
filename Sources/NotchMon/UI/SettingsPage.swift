import AppKit
import SwiftUI

/// Settings, in the notch.
///
/// Not a window, for two reasons. The app is an accessory — no Dock icon, no app
/// menu — so a window is a second surface to manage for a page of toggles. And
/// the setting you change most is *which agents sit in the strip*, which you
/// want to change while looking at the strip rather than behind a window
/// covering it.
///
/// Two columns, because the panel is a wide, short surface. Six groups in one
/// column ran to about 600 points — half the screen height, hanging off the
/// notch. Nothing here scrolls.
struct SettingsPage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    agents
                    appearance
                    general
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    strip
                    refresh
                    alerts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(.top, 13)
    }

    // MARK: Left column

    private var agents: some View {
        Group(title: "Agents") {
            ForEach(store.providers) { snapshot in
                AgentSettingRow(snapshot: snapshot, preferences: preferences)
            }
            if store.providers.isEmpty {
                Text("No agents signed in yet")
                    .font(Typeface.label(10))
                    .foregroundStyle(Palette.faintText)
                    .frame(height: 27, alignment: .leading)
            }
            Text("The strip shows two — pinned first, then whichever you used most recently.")
                .font(Typeface.label(9.5))
                .foregroundStyle(Palette.faintText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }

    /// The swatches change the live theme, so the control is the sample rather
    /// than a description of one.
    private var appearance: some View {
        Group(title: "Appearance") {
            HStack(spacing: 5) {
                ForEach(Theme.allCases) { theme in
                    Button { preferences.theme = theme } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(
                                stops: [
                                    .init(color: theme.swatch.0, location: 0),
                                    .init(color: theme.swatch.0, location: 0.48),
                                    .init(color: theme.swatch.1, location: 0.48),
                                    .init(color: theme.swatch.1, location: 1)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 26)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        preferences.theme == theme ? Palette.control : Palette.hairline,
                                        lineWidth: preferences.theme == theme ? 1.5 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help(theme.name)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(preferences.theme == theme ? [.isSelected] : [])
                }
            }
        }
    }

    private var general: some View {
        Group(title: "General") {
            SettingRow("Open at login") {
                Toggle("", isOn: $preferences.launchAtLogin)
                    .labelsHidden().toggleStyle(NotchToggleStyle())
            }
            SettingRow("Menu bar item") {
                Toggle("", isOn: $preferences.showStatusItem)
                    .labelsHidden().toggleStyle(NotchToggleStyle())
            }
        }
    }

    // MARK: Right column

    private var strip: some View {
        Group(title: "Strip") {
            SettingRow("Right of the notch") {
                Segmented(selection: $preferences.stripRight, options: StripContent.allCases)
            }
            SettingRow("Show on all displays") {
                Toggle("", isOn: $preferences.showOnAllDisplays)
                    .labelsHidden().toggleStyle(NotchToggleStyle())
            }
            // Dimmed rather than hidden when every display already has one:
            // a row that vanishes makes the setting above it look like it did
            // something unrelated.
            SettingRow("Automatically switch displays") {
                Toggle("", isOn: $preferences.autoSwitchDisplays)
                    .labelsHidden().toggleStyle(NotchToggleStyle())
                    .disabled(preferences.showOnAllDisplays)
            }
            .opacity(preferences.showOnAllDisplays ? 0.42 : 1)
            Text(preferences.showOnAllDisplays
                 ? "One strip per display. Only the one under the pointer opens."
                 : (preferences.autoSwitchDisplays
                    ? "Follows the display you are working on — the one whose menu bar is lit."
                    : "Stays on the built-in display, welded to the real notch."))
                .font(Typeface.label(9.5))
                .foregroundStyle(Palette.faintText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }

    /// Two clocks, kept apart because they cost very different things: quotas
    /// hit five vendors' endpoints, the scan only walks local files.
    private var refresh: some View {
        Group(title: "Refresh") {
            SettingRow("Quotas") {
                Segmented(selection: $preferences.quotaInterval,
                          options: [60.0, 180.0, 600.0],
                          label: { Self.minutes($0) })
            }
            SettingRow("Token scan") {
                Segmented(selection: $preferences.scanInterval,
                          options: [300.0, 600.0, 1800.0],
                          label: { Self.minutes($0) })
            }
        }
    }

    private var alerts: some View {
        Group(title: "Alerts") {
            SettingRow("Warn me at") {
                Segmented(selection: $preferences.warnAtPercent,
                          options: [50, 75, 90],
                          label: { "\($0)%" })
            }
            Text("Once per window. The notch flashes and the figure turns red — nothing is sent to Notification Centre.")
                .font(Typeface.label(9.5))
                .foregroundStyle(Palette.faintText)
                .padding(.top, 5)
        }
    }

    private static func minutes(_ seconds: Double) -> String {
        seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h"
    }

    /// Which build is answering, and the way out.
    ///
    /// Only this app's version. tokscale's used to sit alongside it, and
    /// printing it cost a subprocess at every launch — `tokscale --version`,
    /// spawned for one line of text nobody acts on. Which build of the CLI is
    /// installed is the CLI's business.
    ///
    /// Quit lives here rather than in General because it is not a preference:
    /// the toggles above describe how the app behaves next time, and this one
    /// ends it now. The footer's rule is the separation that difference needs.
    private var footer: some View {
        HStack(spacing: 10) {
            Text("notchmon \(Bundle.appVersion)")
                .font(Typeface.number(10, weight: .regular))
                .foregroundStyle(Palette.faintText)
            Spacer(minLength: 0)
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 5) {
                    Image(systemName: Symbol.quit)
                        .font(.system(size: 11.5, weight: .medium))
                    Text("Quit")
                        .font(Typeface.label(11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .help("Quit NotchMon")
            // The word on screen is one syllable; a screen reader needs to know
            // which app it ends.
            .accessibilityLabel("Quit NotchMon")
        }
        .padding(.top, 15)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    // MARK: Pieces

    private struct Group<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(title).padding(.bottom, 8)
                content
            }
            .padding(.top, 13)
        }
    }
}

/// One agent: show it at all, and whether it holds a slot in the strip.
private struct AgentSettingRow: View {
    let snapshot: ProviderSnapshot
    @ObservedObject var preferences: Preferences

    private var isOn: Bool { !preferences.hiddenAgents.contains(snapshot.provider) }
    private var isPinned: Bool { preferences.pinnedAgents.contains(snapshot.provider) }

    var body: some View {
        HStack(spacing: 6) {
            BrandMark(brand: snapshot.brand, size: 12)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.provider)
                    .font(Typeface.label(11.5, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                if let plan = snapshot.plan, !plan.isEmpty {
                    Text(plan)
                        .font(Typeface.label(9.5))
                        .foregroundStyle(Palette.faintText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            Button { preferences.togglePin(snapshot.provider) } label: {
                Image(systemName: isPinned ? Symbol.pinned : Symbol.pin)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(PinButtonStyle(isOn: isPinned))
            .disabled(!isOn)
            .help(isPinned ? "Pinned to the strip" : "Pin to the strip")
            .accessibilityLabel("Pin \(snapshot.provider) to the strip")

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { preferences.setAgent(snapshot.provider, visible: $0) }
            ))
            .labelsHidden()
            .toggleStyle(NotchToggleStyle())
            .accessibilityLabel("Show \(snapshot.provider)")
        }
        .opacity(isOn ? 1 : 0.42)
        .frame(height: 27)
    }
}

// MARK: - Controls

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Typeface.label(11.5))
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: 6)
            control
        }
        .frame(height: 27)
    }
}

struct NotchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Palette.control : Palette.track)
                .frame(width: 27, height: 16)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .clickable()
        .animation(.easeOut(duration: 0.16), value: configuration.isOn)
    }
}

struct PinButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Palette.control : Palette.faintText)
            .frame(width: 22, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn || configuration.isPressed ? Palette.hover : .clear)
            }
            .contentShape(Rectangle())
            .clickable()
    }
}

/// A selected segment takes the panel's own surface as its text colour, so the
/// pair stays legible on a brass theme and a pale grey one alike.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var label: (Value) -> String

    init(selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option))
                        .font(Typeface.number(10, weight: .medium))
                        .monospacedDigit()
                        // Every segment pins its own ideal width. Without it the
                        // group negotiates and the longest label truncates —
                        // "Tokens" arrived on screen as "Toke…".
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selection == option ? Palette.surface : Palette.secondaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == option ? Palette.control : .clear)
                        }
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.track)
        }
    }
}

extension Segmented where Value: SegmentLabelled {
    init(selection: Binding<Value>, options: [Value]) {
        self.init(selection: selection, options: options, label: { $0.segmentLabel })
    }
}

protocol SegmentLabelled: Hashable {
    var segmentLabel: String { get }
}

extension Bundle {
    static var appVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
