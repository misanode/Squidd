import SwiftUI
import AppKit
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsActions {
    var close: () -> Void = {}
    var resetPosition: () -> Void = {}
    var saveDefaultSize: () -> Void = {}
    var resetSize: () -> Void = {}
}

@MainActor
final class SettingsWindow: NSWindow {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Squidd Settings"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbar = NSToolbar(identifier: "SquiddSettings")
        toolbarStyle = .unifiedCompact
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.fullScreenNone]
        contentMinSize = SettingsView.minimumSize
        isReleasedWhenClosed = false
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", music = "Music", appearance = "Appearance", keybinds = "Keybinds"

    var id: Self { self }
    var icon: String { "tab-\(rawValue.lowercased())" }
}

struct SettingsView: View {
    static let defaultSize = CGSize(width: 448, height: 500)
    static let minimumSize = CGSize(width: 448, height: 360)

    @Bindable var store: AppStore
    var actions: SettingsActions
    @State private var tab: SettingsTab
    @State private var keepOnTop = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(store: AppStore, actions: SettingsActions = SettingsActions()) {
        _store = Bindable(store)
        self.actions = actions
        _tab = State(initialValue: store.playback.needsAttention ? .music : .general)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Squidd Settings").font(SettingsStyle.font(12.5))
                .frame(height: 42)
                .accessibilityAddTraits(.isHeader)
            tabBar.padding(.top, 8)
            card.padding(.top, 12.5).padding(.horizontal, 42.5).padding(.bottom, 43.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { glass }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background { Button("Close", action: actions.close).keyboardShortcut(.cancelAction).hidden() }
        .contextMenu {
            Button("Set Current Size as Default", action: actions.saveDefaultSize)
            Button("Reset Size", action: actions.resetSize)
        }
    }

    @ViewBuilder private var glass: some View {
        if reduceTransparency {
            SettingsStyle.window
        } else {
            ZStack {
                Rectangle().fill(.ultraThickMaterial)
                Color.black.opacity(0.35)
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.2)), in: Rectangle())
            }
        }
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SettingsTab.allCases) { item in
                if item != .general { Spacer(minLength: 8) }
                tabButton(item)
            }
        }
        .padding(.horizontal, 58.5)
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let selected = tab == item
        return Button { tab = item } label: {
            VStack(spacing: 3.5) {
                Group {
                    if selected { Icon(item.icon + "-active", scale: 0.2) } else { Icon(item.icon, scale: 0.2) }
                }
                .frame(width: 40, height: 40)
                Text(item.rawValue).font(SettingsStyle.font(9.5)).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var card: some View {
        Group {
            switch tab {
            case .general: general
            case .music: music
            case .appearance: appearance
            case .keybinds: keybinds
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsStyle.card, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func page<Content: View>(leading: CGFloat = 31, trailing: CGFloat = 31, bottom: CGFloat,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        let rows = SpreadStack(bottom: bottom) { content() }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
        return ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }.scrollIndicators(.automatic)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(SettingsStyle.font(9.5)).accessibilityAddTraits(.isHeader)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(SettingsStyle.label).foregroundStyle(SettingsStyle.secondary).lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func row<Control: View>(_ icon: String, _ text: String, spacing: CGFloat = 5.5,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 0) {
            Icon(icon)
            label(text).padding(.leading, spacing)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 20)
    }

    private func note(_ text: String, error: Bool = false) -> some View {
        Text(text).font(SettingsStyle.label)
            .foregroundStyle(error ? SettingsStyle.errorText : SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var general: some View {
        page(leading: 38, trailing: 43, bottom: 17.5) {
            header("Updates").gap(47)
            row("general-version", "Squidd version \(Self.version)") {
                Button("Check For Updates") {}.buttonStyle(OutlineButtonStyle(width: 97.5))
            }
            .gap(20)
            header("Behavior").gap(20)
            row("general-reset-position", "Reset Position") {
                Button("Reset", action: actions.resetPosition).buttonStyle(OutlineButtonStyle(width: 52.5))
                    .accessibilityLabel("Reset player position")
            }
            .gap(16)
            row("general-keep-on-top", "Keep on top of all windows", spacing: 4.5) {
                Toggle("Keep on top of all windows", isOn: $keepOnTop).toggleStyle(SwitchStyle())
            }
            .gap(21)
            header("Startup").gap(23.5)
            row(launchAtLogin ? "general-startup-on" : "general-startup-off", loginText, spacing: 4) {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { _ in store.toggleLogin() }))
                    .toggleStyle(SwitchStyle())
            }
            .gap(16.5)
            if let error = store.preferenceError, !error.hasPrefix(AppStore.mascotErrorPrefix) {
                note(error, error: true).gap(8)
            }
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 4) {
                    Icon("general-startup-off", scale: 0.15)
                    label("Quit")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quit Squidd")
            .frame(maxWidth: .infinity)
            .gap(23)
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var launchAtLogin: Bool { store.loginStatus == .enabled }

    private var loginText: String {
        switch store.loginStatus {
        case .requiresApproval, .notFound: store.loginDescription
        default: "Squidd will automatically open at login"
        }
    }

    private var music: some View {
        page(bottom: 33) {
            header("Music").gap(50)
            row(store.playback.app == .spotify ? "music-spotify" : "music-connected", store.playback.status,
                spacing: 7) {
                Button(actionTitle, action: { fix(store.playback.app) })
                    .buttonStyle(OutlineButtonStyle(width: 108.5))
                    .disabled(action == nil)
                    .accessibilityIdentifier("musicConnectionAction")
            }
            .gap(17.5)
            if let note = store.playback.message { self.note(note).gap(27) }
            ForEach(MusicApp.allCases, id: \.self) { app in
                row("music-connected", "Squidd can control \(app.name)", spacing: 3.5) {
                    Toggle("Squidd can control \(app.name)", isOn: automationAllowed(app)).toggleStyle(SwitchStyle())
                        .accessibilityIdentifier("\(app.rawValue)AutomationStatus")
                }
                .gap(app == MusicApp.allCases.last ? 30 : 17.5)
            }
            note("Squidd shows whichever of Spotify or Apple Music last started playing on this Mac. Playing on "
                 + "another device won’t appear here.")
            .gap(33.5)
        }
    }

    private enum ConnectionAction { case openApp, requestPermission, openPrivacySettings }

    private var action: ConnectionAction? {
        switch store.playback.state {
        case .notRunning: .openApp
        case .permissionNeeded: .requestPermission
        case .permissionDenied: .openPrivacySettings
        default: nil
        }
    }

    private var actionTitle: String {
        switch action {
        case .openApp: "Open \(store.playback.app.name)"
        case .requestPermission: "Allow Access"
        case .openPrivacySettings: "Open Settings"
        case nil: "Connected"
        }
    }

    private func fix(_ app: MusicApp) {
        switch Automation.permission(for: app) {
        case .appNotRunning: app.open()
        case .notAsked:
            _ = Automation.permission(for: app, askIfNeeded: true)
            store.playback.retry()
        case .denied: Automation.openPrivacySettings()
        case .granted: break
        }
    }

    private func automationAllowed(_ app: MusicApp) -> Binding<Bool> {
        Binding(get: { Automation.permission(for: app) == .granted }, set: { on in
            guard on else { Automation.openPrivacySettings(); return }
            fix(app)
        })
    }

    private var appearance: some View {
        page(leading: 30, trailing: 30, bottom: 24.5) {
            header("Appearance").gap(26.5)
            row(store.widgetAppearance.isDark ? "appearance-moon" : "appearance-sun",
                "Currently on \(store.widgetAppearance.rawValue)", spacing: 8) {
                Toggle("Dark appearance", isOn: Binding(get: { store.widgetAppearance.isDark },
                                                         set: { store.widgetAppearance = $0 ? .dark : .light }))
                    .toggleStyle(SwitchStyle())
            }
            .gap(13)
            header("Pill").gap(11)
            HStack(alignment: .top, spacing: 0) {
                ForEach(PillLayout.allCases) { layout in
                    if layout != .logo { Spacer(minLength: 8) }
                    pillOption(layout)
                }
            }
            .padding(.trailing, 5)
            .gap(1)
            header("Accent Colors").gap(15)
            accentColors.gap(8.5)
            header("Mascot").gap(14)
            HStack(spacing: 0) {
                mascotPreview
                label("Mascot appears in the pill").padding(.leading, 4)
                Spacer(minLength: 12)
                Button("Remove") { store.resetCustomMascot() }
                    .buttonStyle(OutlineButtonStyle(width: 44.5))
                    .accessibilityLabel("Remove mascot")
                    .shown(store.customMascotPath != nil)
                Spacer(minLength: 8).frame(maxWidth: 15.5)
                Button("Choose GIF or image…") { pickMascot() }
                    .buttonStyle(OutlineButtonStyle(width: 108.5))
            }
            .frame(minHeight: 20)
            .gap(8)
            if let error = store.preferenceError, error.hasPrefix(AppStore.mascotErrorPrefix) {
                note(error, error: true).gap(8)
            }
            HStack(spacing: 0) {
                Icon("appearance-outline")
                label("Appears outside window").padding(.leading, 4)
                Spacer(minLength: 8).frame(maxWidth: 13.5)
                Toggle("Dashed outline around player", isOn: $store.showCardOutline).toggleStyle(SwitchStyle())
                Spacer(minLength: 12)
                Icon("appearance-music-notes")
                label("While song plays").padding(.leading, 3)
                Spacer(minLength: 8).frame(maxWidth: 7.5)
                Toggle("Music notes while playing", isOn: $store.showMusicNotes).toggleStyle(SwitchStyle())
            }
            .gap(21.5)
        }
    }

    private func pillOption(_ layout: PillLayout) -> some View {
        let selected = store.showPillArtwork == layout.artwork && store.showMascot == layout.mascot
        return Button {
            store.showPillArtwork = layout.artwork
            store.showMascot = layout.mascot
        } label: {
            VStack(spacing: 2) {
                label(layout.caption)
                Icon(layout.icon)
                Image(systemName: selected ? "checkmark.circle.fill" : "checkmark.circle")
                    .symbolRenderingMode(selected ? .palette : .monochrome)
                    .foregroundStyle(selected ? SettingsStyle.card : .white, .white.opacity(0.85))
                    .font(.system(size: 11))
                    .padding(.top, 4)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.caption)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var accentColors: some View {
        HStack(alignment: .bottom, spacing: 0) {
            captioned("Logo") { Icon("appearance-accent-logo") }
            Spacer(minLength: 4).frame(maxWidth: 6)
            captioned {
                swatches([
                    (store.logoPrimaryColor, "Logo primary", { store.logoPrimaryHex = $0.hexString }),
                    (store.logoHighlightColor, "Logo highlight", { store.logoHighlightHex = $0.hexString }),
                    (store.logoCircleColor, "Logo circle", { store.logoCircleHex = $0.hexString }),
                ])
            }
            Spacer(minLength: 6).frame(maxWidth: 12)
            captioned("Pill") { Icon("appearance-accent-pill") }
            Spacer(minLength: 6).frame(maxWidth: 12)
            captioned {
                swatches([(store.rimAccentColor, "Pill highlight", { store.rimAccentHex = $0.hexString })])
            }
            Spacer(minLength: 8)
            captioned {
                Button("Reset") { store.resetAccentColors() }
                    .buttonStyle(OutlineButtonStyle(width: 35.5))
                    .accessibilityLabel("Reset accent colors")
                    .shown(!store.accentIsDefault)
            }
        }
    }

    private func captioned<Content: View>(_ caption: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 3) {
            label(caption ?? " ").opacity(caption == nil ? 0 : 1).accessibilityHidden(caption == nil)
            content().frame(height: 27)
        }
    }

    private func swatches(_ items: [(Color, String, (Color) -> Void)]) -> some View {
        HStack(spacing: 22) {
            ForEach(items.indices, id: \.self) { index in
                ColorSwatch(color: items[index].0, label: items[index].1, onChange: items[index].2)
            }
        }
        .padding(.horizontal, 10.5)
        .frame(height: 23)
        .background(SettingsStyle.window, in: RoundedRectangle(cornerRadius: 4))
    }

    private var mascotPreview: some View {
        Group {
            if let url = store.customMascotURL, let image = firstFrame(of: url) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 18.5, height: 18.5).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Icon("appearance-mascot")
            }
        }
        .accessibilityHidden(true)
    }

    private var keybinds: some View {
        page(leading: 29.5, trailing: 65, bottom: 29) {
            header("Music Player").gap(29)
            keybind(icon: "keybind-player", "Toggle visibility of music player", labelGap: 7.5, key: "keybind-slash")
                .gap(15)
            header("Window").padding(.leading, 2).gap(46)
            keybind(chevron: 0, "Move the window up").gap(12.5)
            keybind(chevron: 90, "Move the window right").gap(20.5)
            keybind(chevron: 180, "Move the window down").gap(18)
            keybind(chevron: 270, "Move the window left").gap(21)
            ForEach(store.shortcutErrors, id: \.self) { note($0, error: true).gap(8) }
        }
    }

    private func keybind(chevron degrees: Double, _ text: String) -> some View {
        keybind(icon: "keybind-chevron", rotation: degrees + 180, text, labelGap: 18, key: "keybind-arrow",
                keyRotation: degrees)
    }

    private func keybind(icon: String, rotation: Double = 0, _ text: String, labelGap: CGFloat, key: String,
                         keyRotation: Double = 0) -> some View {
        HStack(spacing: 0) {
            Icon(icon).rotationEffect(.degrees(rotation)).frame(width: 29, height: 25)
            label(text).padding(.leading, labelGap)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Icon("keybind-cmd", scale: 0.17)
                Text("+").font(.system(size: 16, weight: .light)).foregroundStyle(SettingsStyle.secondary)
                Icon(key).rotationEffect(.degrees(keyRotation)).frame(width: 20, height: 20)
            }
            .frame(width: 64, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func firstFrame(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func pickMascot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { store.setCustomMascot(from: url) }
    }
}

private enum PillLayout: CaseIterable, Identifiable {
    case logo, mascot, album, both

    var id: Self { self }
    var artwork: Bool { self == .album || self == .both }
    var mascot: Bool { self == .mascot || self == .both }
    var caption: String { self == .logo ? "Logo" : self == .both ? "Logo + 2 items" : "Logo + 1 item" }
    var icon: String {
        switch self {
        case .logo: "appearance-pill-logo"
        case .mascot: "appearance-pill-mascot"
        case .album: "appearance-pill-album"
        case .both: "appearance-pill-both"
        }
    }
}

private enum SettingsStyle {
    static let window = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255)
    static let card = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
    static let field = Color.white.opacity(0.16)
    static let secondary = Color.white.opacity(0.5)
    static let errorText = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let label = font(7.5, .regular)
    static let unit: CGFloat = 0.162

    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}

private struct Icon: View {
    var name: String
    var scale: CGFloat

    init(_ name: String, scale: CGFloat = SettingsStyle.unit) {
        self.name = name
        self.scale = scale
    }

    var body: some View {
        let size = NSImage(named: name)?.size ?? .zero
        Image(name).resizable()
            .frame(width: size.width * scale, height: size.height * scale)
            .accessibilityHidden(true)
    }
}

nonisolated private struct SpreadGap: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private extension View {
    func gap(_ value: CGFloat) -> some View { layoutValue(key: SpreadGap.self, value: value) }

    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).disabled(!visible).accessibilityHidden(!visible)
    }
}

private struct SpreadStack: Layout {
    var bottom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let natural = heights(width, subviews).reduce(0, +) + gaps(subviews).reduce(0, +)
        let height = proposal.height.flatMap { $0.isFinite ? max($0, natural) : nil } ?? natural
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(bounds.width, subviews), gaps = gaps(subviews)
        let totalGap = gaps.reduce(0, +)
        let extra = max(0, bounds.height - heights.reduce(0, +) - totalGap)
        let stretch = totalGap > 0 ? 1 + extra / totalGap : 1
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            y += gaps[index] * stretch
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y += heights[index]
        }
    }

    private func heights(_ width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    private func gaps(_ subviews: Subviews) -> [CGFloat] { subviews.map { $0[SpreadGap.self] } + [bottom] }
}

private struct OutlineButtonStyle: ButtonStyle {
    var width: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsStyle.font(9))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: width, minHeight: 19)
            .padding(.horizontal, 2)
            .overlay(Capsule().strokeBorder(.white, lineWidth: 1.2))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.4)
    }
}

private struct SwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            Capsule().strokeBorder(.white, lineWidth: 1.2)
                .frame(width: 38.5, height: 19)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 14, height: 14).padding(.horizontal, 2.5)
                }
                .opacity(configuration.isOn ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct ColorSwatch: View {
    var color: Color
    var label: String
    var onChange: (Color) -> Void

    var body: some View {
        Button { ColorPanelBridge.shared.open(initial: color, onChange: onChange) } label: {
            Circle().fill(color)
                .frame(width: 13, height: 13)
                .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) color")
    }
}

private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Color) -> Void)?

    func open(initial: Color, onChange: @escaping (Color) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) { onChange?(Color(nsColor: sender.color)) }
}
