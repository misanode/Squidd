import AppKit
import ImageIO
import Observation
import ServiceManagement
import SwiftUI

enum PreviewState: String, CaseIterable, Identifiable {
    case off = "Off", playing = "Playing", paused = "Paused", idle = "Idle", error = "Error"
    var id: String { rawValue }
}

enum InkMode: String, CaseIterable {
    case automatic = "Automatic", white = "White", dark = "Dark grey", scrim = "White on scrim"
}

nonisolated enum MascotLimits {
    static let maxBytes = 25_000_000
    static let maxFrames = 600
    static let maxDimension = 4096
    static let maxTotalPixels = 500_000_000
}

enum WidgetAppearance: String, CaseIterable {
    case light = "Light", dark = "Dark"

    var isDark: Bool { self == .dark }
}

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex.removeAll { $0 == "#" }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
    }
}

@MainActor @Observable
final class AppStore {
    let playback: Playback
    var preview: PreviewState = .off
    var cardVisible = true { didSet { playback.setBackground(!cardVisible) } }
    var sleeping = false
    var logoPressed = false
    private var previewElapsed: Double = 0
    private let previewDuration: Double = 212
    var elapsed: Double { preview == .off ? playback.elapsed : previewElapsed }
    var duration: Double { preview == .off ? playback.duration : previewDuration }
    var sampleIndex = 0
    var shortcutErrors: [String] = []
    var preferenceError: String?
    var loginStatus = SMAppService.mainApp.status
    var automation: [MusicApp: Automation.Permission] = [:]
    var inkChoices: [String: String]
    var customMascotPath: String? { didSet { defaults.set(customMascotPath, forKey: "customMascotPath") } }
    var rimAccentHex: String? { didSet { defaults.set(rimAccentHex, forKey: "rimAccentHex") } }
    var showCardOutline: Bool { didSet { defaults.set(showCardOutline, forKey: "showCardOutline") } }
    var widgetAppearance: WidgetAppearance { didSet { defaults.set(widgetAppearance.rawValue, forKey: "widgetAppearance") } }
    var logoPrimaryHex: String? { didSet { defaults.set(logoPrimaryHex, forKey: "logoPrimaryHex") } }
    var logoHighlightHex: String? { didSet { defaults.set(logoHighlightHex, forKey: "logoHighlightHex") } }
    var logoCircleHex: String? { didSet { defaults.set(logoCircleHex, forKey: "logoCircleHex") } }
    var showPillArtwork: Bool { didSet { defaults.set(showPillArtwork, forKey: "showPillArtwork") } }
    var showMascot: Bool { didSet { defaults.set(showMascot, forKey: "showMascot") } }
    var showMusicNotes: Bool { didSet { defaults.set(showMusicNotes, forKey: "showMusicNotes") } }
    var keepOnTop: Bool { didSet { defaults.set(keepOnTop, forKey: "keepOnTop") } }
    static let defaultLogoPrimary = Color(hex: "#8D0404") ?? Color(red: 0.55, green: 0.02, blue: 0.02)
    static let defaultLogoHighlight = Color(hex: "#E54B4B") ?? Color(red: 0.9, green: 0.3, blue: 0.3)
    static let defaultLogoCircle = Color.black
    static let defaultRimAccent = Color(hex: "#FAFFF5") ?? .white
    private let defaults: UserDefaults
    private var tick: Task<Void, Never>?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init(defaults: UserDefaults = .standard, source: (any NowPlayingSource)? = nil,
         observeNotifications: Bool = true) {
        self.defaults = defaults
        if let url = Bundle.main.url(forResource: "AppearanceDefaults", withExtension: "plist"),
           let shipped = NSDictionary(contentsOf: url) as? [String: Any] {
            defaults.register(defaults: shipped.filter { Self.launchDefaultKeys.contains($0.key) })
        }
        playback = Playback(source: source, pollInterval: 15, idlePollInterval: 30,
                                   backgroundPollInterval: 60, boostInterval: 2,
                                   observeNotifications: observeNotifications)
        inkChoices = defaults.dictionary(forKey: "inkOverrides") as? [String: String] ?? [:]
        customMascotPath = defaults.string(forKey: "customMascotPath")
        rimAccentHex = defaults.string(forKey: "rimAccentHex")
        showCardOutline = defaults.object(forKey: "showCardOutline") as? Bool ?? true
        let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        widgetAppearance = WidgetAppearance(rawValue: defaults.string(forKey: "widgetAppearance") ?? "")
            ?? (systemDark ? .dark : .light)
        logoPrimaryHex = defaults.string(forKey: "logoPrimaryHex")
        logoHighlightHex = defaults.string(forKey: "logoHighlightHex")
        logoCircleHex = defaults.string(forKey: "logoCircleHex")
        showPillArtwork = defaults.object(forKey: "showPillArtwork") as? Bool ?? true
        showMascot = defaults.object(forKey: "showMascot") as? Bool ?? true
        showMusicNotes = defaults.object(forKey: "showMusicNotes") as? Bool ?? true
        keepOnTop = defaults.object(forKey: "keepOnTop") as? Bool ?? true
    }

    static let launchDefaultKeys: Set<String> = [
        "rimAccentHex", "showCardOutline", "logoPrimaryHex", "logoHighlightHex", "logoCircleHex",
        "showPillArtwork", "showMascot", "showMusicNotes", "defaultPosition", "settingsDefaultSize",
    ]

    var appearanceSnapshot: [String: Any] {
        let values: [String: Any?] = [
            "rimAccentHex": rimAccentHex, "showCardOutline": showCardOutline,
            "logoPrimaryHex": logoPrimaryHex, "logoHighlightHex": logoHighlightHex, "logoCircleHex": logoCircleHex,
            "showPillArtwork": showPillArtwork, "showMascot": showMascot, "showMusicNotes": showMusicNotes,
        ]
        return values.compactMapValues { $0 }
    }

    func refreshAutomation() async {
        automation = await Task.detached {
            Dictionary(uniqueKeysWithValues: MusicApp.allCases.map { ($0, Automation.permission(for: $0)) })
        }.value
    }

    func requestAutomation(for app: MusicApp) async {
        _ = await Task.detached { Automation.permission(for: app, askIfNeeded: true) }.value
        await refreshAutomation()
        playback.retry()
    }

    func setSuspended(_ value: Bool) { playback.setSuspended(value) }
    func boostPlayback(for seconds: Double = 45) { playback.boost(for: seconds) }

    var customMascotURL: URL? { customMascotPath.map { URL(fileURLWithPath: $0) } }
    var pillShowsMascot: Bool { showMascot }
    var rimPrimaryColor: Color { logoPrimaryColor }
    var rimAccentColor: Color { rimAccentHex.flatMap { Color(hex: $0) } ?? AppStore.defaultRimAccent }

    var logoPrimaryColor: Color { logoPrimaryHex.flatMap { Color(hex: $0) } ?? AppStore.defaultLogoPrimary }
    var logoHighlightColor: Color { logoHighlightHex.flatMap { Color(hex: $0) } ?? AppStore.defaultLogoHighlight }
    var logoCircleColor: Color { logoCircleHex.flatMap { Color(hex: $0) } ?? AppStore.defaultLogoCircle }
    var accentIsDefault: Bool {
        logoPrimaryColor.hexString == AppStore.defaultLogoPrimary.hexString
            && logoHighlightColor.hexString == AppStore.defaultLogoHighlight.hexString
            && logoCircleColor.hexString == AppStore.defaultLogoCircle.hexString
            && rimAccentColor.hexString == AppStore.defaultRimAccent.hexString
    }

    func resetAccentColors() {
        logoPrimaryHex = nil
        logoHighlightHex = nil
        logoCircleHex = nil
        rimAccentHex = nil
    }

    private var customAssetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Squidd", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func removingExisting(prefix: String, in directory: URL, except kept: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix) && item.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static let mascotErrorPrefix = "Custom mascot"
    private static let mascotFilePrefix = "custom-mascot-"

    private func isManagedMascot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let resolved = { (directory: URL) in directory.standardizedFileURL.resolvingSymlinksInPath().path }
        return url.lastPathComponent.hasPrefix(Self.mascotFilePrefix)
            && resolved(url.deletingLastPathComponent()) == resolved(customAssetsDirectory)
    }

    private func mascotProblem(at source: URL) -> String? {
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes <= MascotLimits.maxBytes else { return "File is larger than \(MascotLimits.maxBytes / 1_000_000) MB." }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return "Not a supported image." }
        let frames = CGImageSourceGetCount(image)
        guard frames > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return "Not a supported image." }
        guard frames <= MascotLimits.maxFrames else { return "Too many frames (max \(MascotLimits.maxFrames))." }
        guard max(width, height) <= MascotLimits.maxDimension else {
            return "Image is larger than \(MascotLimits.maxDimension) px."
        }
        guard width * height * frames <= MascotLimits.maxTotalPixels else { return "Animation is too large." }
        return nil
    }

    func setCustomMascot(from source: URL) {
        if let problem = mascotProblem(at: source) {
            preferenceError = "\(Self.mascotErrorPrefix): \(problem)"
            return
        }
        let directory = customAssetsDirectory
        let ext = source.pathExtension.isEmpty ? "gif" : source.pathExtension
        let destination = directory.appendingPathComponent("\(Self.mascotFilePrefix)\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            removingExisting(prefix: Self.mascotFilePrefix, in: directory, except: destination.lastPathComponent)
            customMascotPath = destination.path
            preferenceError = nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            preferenceError = "\(Self.mascotErrorPrefix): \(error.localizedDescription)"
        }
    }

    func resetCustomMascot() {
        if let path = customMascotPath, isManagedMascot(path) { try? FileManager.default.removeItem(atPath: path) }
        customMascotPath = nil
        if preferenceError?.hasPrefix(Self.mascotErrorPrefix) == true { preferenceError = nil }
    }

    var isPlaying: Bool { preview == .off ? playback.isPlaying : preview == .playing }
    var canControl: Bool {
        preview == .off ? (playback.permits(.play) || playback.permits(.pause) || playback.permits(.next) || playback.permits(.previous))
            : preview == .playing || preview == .paused
    }
    var canSeek: Bool { preview == .off ? playback.permits(.seek(elapsed)) : canControl }
    var title: String { preview == .off ? playback.title : (canControl ? (sampleIndex == 0 ? "Preview track" : "Preview track 2") : "Nothing playing") }
    var artist: String {
        switch preview {
        case .off: playback.artist
        case .idle: "Preview · No active device"
        case .error: "Preview · Playback unavailable"
        default: sampleIndex == 0 ? "Preview · Squidd" : "Preview · Sabrina Carpenter"
        }
    }
    var artworkKey: String { preview == .off ? playback.artworkKey : (canControl ? "preview://artwork/\(sampleIndex)" : "idle") }
    var trackIdentity: String { preview == .off ? playback.identity : "preview:\(sampleIndex)" }
    var artwork: NSImage? { preview == .off ? playback.artwork : nil }
    var showsArtwork: Bool { preview == .off ? artworkKey != "idle" : canControl }
    var pillShowsArtwork: Bool { showPillArtwork }
    private var inkKey: String { preview == .off ? playback.loadedArtworkKey : artworkKey }
    var ink: InkMode { InkMode(rawValue: inkChoices[inkKey] ?? "") ?? .automatic }
    var shownDuration: Double { preview == .off ? playback.duration : (canControl ? duration : 0) }
    var showsTimeline: Bool { preview == .off ? playback.duration > 0 : canControl }

    func permits(_ command: PlaybackCommand) -> Bool { preview == .off ? playback.permits(command) : canControl }
    func offers(_ command: PlaybackCommand) -> Bool { preview == .off ? playback.offers(command) : canControl }

    func setInk(_ mode: InkMode) {
        if mode == .automatic { inkChoices.removeValue(forKey: inkKey) }
        else { inkChoices[inkKey] = mode.rawValue }
        defaults.set(inkChoices, forKey: "inkOverrides")
    }

    func forgetInk() { inkChoices = [:]; defaults.removeObject(forKey: "inkOverrides") }

    func selectPreview(_ state: PreviewState) {
        preview = state
        previewElapsed = 0
        playback.setPreviewing(state != .off)
        reconcileClock()
    }

    func togglePlayback() {
        if preview == .off { playback.send(isPlaying ? .pause : .play); return }
        guard canControl else { return }
        preview = isPlaying ? .paused : .playing
        reconcileClock()
    }

    func skip(previous: Bool = false) {
        if preview == .off { playback.send(previous ? .previous : .next); return }
        guard canControl else { return }; sampleIndex = 1 - sampleIndex; previewElapsed = 0
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        if preview == .off { playback.send(.seek(seconds)); return }
        guard canControl else { return }; previewElapsed = max(0, min(seconds, duration))
    }

    func openPlayer() { playback.app.open() }

    func reconcileClock() {
        tick?.cancel()
        tick = nil
        guard preview == .playing && !sleeping else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        tick = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { break }
                let now = ProcessInfo.processInfo.systemUptime
                self.previewElapsed = min(self.duration, self.previewElapsed + now - self.lastTick)
                self.lastTick = now
                if self.elapsed >= self.duration { self.skip() }
            }
        }
    }

    func stop() {
        tick?.cancel(); tick = nil
        playback.stop()
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
            preferenceError = nil
        } catch { preferenceError = "Launch at Login: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }

    var loginDescription: String {
        switch loginStatus {
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings"
        case .notRegistered: "Off"
        case .notFound: "Unavailable for this app installation"
        @unknown default: "Unknown"
        }
    }
}
