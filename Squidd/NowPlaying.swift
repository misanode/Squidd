import AppKit
import Carbon
import Foundation
import os

nonisolated enum PlaybackCommand: Equatable, Sendable {
    case play, pause, previous, next, seek(Double)
}

/// The music apps Squidd can follow. Both are read the same way — Apple Events plus the app's own broadcast — and
/// Squidd shows whichever one most recently started playing.
nonisolated enum MusicApp: String, CaseIterable, Sendable {
    case spotify, music

    var bundleIdentifier: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }

    /// The distributed notification the app posts on every play, pause and track change.
    var broadcast: Notification.Name {
        switch self {
        case .spotify: .init("com.spotify.client.PlaybackStateChanged")
        case .music: .init("com.apple.Music.playerInfo")
        }
    }

    init?(bundleIdentifier: String?) {
        guard let match = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = match
    }

    /// Apps are only addressed while already running — addressing a stopped app would launch it, and Squidd opening
    /// a music app on its own would be a surprise.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

/// What Squidd needs from a music app. Spotify and Apple Music each have one.
protocol NowPlayingSource: Sendable {
    func snapshot() async throws -> NowPlayingSnapshot?
    /// Fetched on its own because neither app's broadcast includes it: Spotify's is a URL, Apple Music's is the
    /// image itself, which is too heavy to read on every poll.
    func artwork(for trackID: String) async throws -> ArtworkReference?
    func send(_ command: PlaybackCommand) async throws
}

/// Where a track's cover comes from. `key` identifies the image for caching and for per-artwork ink choices.
nonisolated enum ArtworkReference: Equatable, Sendable {
    /// Spotify: an `i.scdn.co` link.
    case remote(URL)
    /// Apple Music: the image bytes, read straight out of the app.
    case embedded(key: String, data: Data)

    var key: String {
        switch self {
        case .remote(let url): url.absoluteString
        case .embedded(let key, _): key
        }
    }
}

// MARK: - Snapshot

/// One reading of a music app's player. Built either from the app's broadcast (free, and how most readings arrive)
/// or from Apple Events (at launch, and as a safety net).
nonisolated struct NowPlayingSnapshot: Equatable, Sendable {
    enum PlayState: Sendable, Equatable { case playing, paused, stopped }

    var app: MusicApp = .spotify
    var state: PlayState = .stopped
    /// Spotify: `spotify:track:…`, and also `spotify:ad:…` or `spotify:local:…`, which is how ads and local files
    /// are spotted. Apple Music: `music:` and the track's persistent ID.
    var trackID = ""
    var name = ""
    var artist = ""
    var album = ""
    /// Spotify only; Apple Music hands over image bytes instead, through `NowPlayingSource.artwork(for:)`.
    var artworkURL: URL?
    var hasArtwork = false
    /// Spotify reports duration in **milliseconds**, though its scripting dictionary says seconds. Both the Apple
    /// Event and the notification agree on milliseconds; `duration` does the conversion. Apple Music's broadcast
    /// also uses milliseconds, its Apple Events seconds, and its bridge converts.
    var durationMilliseconds: Double = 0
    /// Seconds — unlike `durationMilliseconds`. Nil when the reading didn't include one: Apple Music's broadcast
    /// leaves the position out.
    var positionSeconds: Double? = 0

    var isPlaying: Bool { state == .playing }
    var isLoaded: Bool { !trackID.isEmpty && state != .stopped }
    var isAd: Bool { trackID.hasPrefix("spotify:ad:") }
    var isLocal: Bool { trackID.hasPrefix("spotify:local:") }

    var duration: Double { min(Double(Int32.max) / 1000, max(0, durationMilliseconds / 1000)) }
    var elapsed: Double { min(duration, max(0, positionSeconds ?? 0)) }
    var identity: String { trackID.isEmpty ? "idle" : trackID }
    var title: String {
        if isAd { return "Advertisement" }
        if !name.isEmpty { return name }
        return isPlaying ? "Playback unavailable" : "Nothing playing"
    }

    /// Neither scripting interface says which commands the current item allows, so anything loaded and not an ad
    /// is fair game; the app simply ignores a command it cannot honor.
    func permits(_ command: PlaybackCommand) -> Bool {
        guard isLoaded, !isAd else { return false }
        if case .seek = command { return duration > 0 }
        return true
    }

    /// Apple Music's persistent IDs arrive as hex text over Apple Events and as a number in the broadcast. Both are
    /// normalized to the same 16-digit uppercase form so a track keeps one identity whichever way it was read.
    static func musicTrackID(_ persistentID: UInt64) -> String {
        let hex = String(persistentID, radix: 16, uppercase: true)
        return "music:" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    static func musicTrackID(hex: String) -> String? {
        UInt64(hex, radix: 16).map(musicTrackID)
    }
}

extension NowPlayingSnapshot {
    init?(notification userInfo: [AnyHashable: Any], from app: MusicApp) {
        switch app {
        case .spotify: self.init(spotifyNotification: userInfo)
        case .music: self.init(musicNotification: userInfo)
        }
    }

    /// Keys Spotify puts in its `PlaybackStateChanged` notification. Verified live; `userInfo` survives the App
    /// Sandbox intact, so a state change needs no Apple Event at all.
    init?(spotifyNotification userInfo: [AnyHashable: Any]) {
        guard let state = Self.playState(userInfo) else { return nil }
        self.state = state
        trackID = userInfo["Track ID"] as? String ?? ""
        name = userInfo["Name"] as? String ?? ""
        artist = userInfo["Artist"] as? String ?? ""
        album = userInfo["Album"] as? String ?? ""
        durationMilliseconds = (userInfo["Duration"] as? NSNumber)?.doubleValue ?? 0
        positionSeconds = (userInfo["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        // The one thing the notification leaves out is the artwork URL; `Has Artwork` says whether fetching one is
        // worth an Apple Event.
        hasArtwork = ((userInfo["Has Artwork"] as? NSNumber)?.boolValue ?? false)
    }

    /// Keys Apple Music puts in `com.apple.Music.playerInfo`. It carries no playback position, so the controller
    /// reads that over Apple Events, and no artwork flag, so artwork is always looked up once per track.
    init?(musicNotification userInfo: [AnyHashable: Any]) {
        guard let state = Self.playState(userInfo) else { return nil }
        app = .music
        self.state = state
        name = userInfo["Name"] as? String ?? ""
        artist = userInfo["Artist"] as? String ?? ""
        album = userInfo["Album"] as? String ?? ""
        durationMilliseconds = (userInfo["Total Time"] as? NSNumber)?.doubleValue ?? 0
        positionSeconds = nil
        if let id = userInfo["PersistentID"] as? NSNumber {
            trackID = Self.musicTrackID(UInt64(bitPattern: id.int64Value))
        }
        hasArtwork = isLoaded
    }

    private static func playState(_ userInfo: [AnyHashable: Any]) -> PlayState? {
        switch userInfo["Player State"] as? String {
        case "Playing": .playing
        case "Paused": .paused
        case .some: .stopped
        case nil: nil
        }
    }
}

// MARK: - Errors

nonisolated enum PlayerBridgeError: Error, Equatable {
    case notRunning
    case permissionDenied
    case timedOut
    case nothingPlaying
    case failed(OSStatus)

    func description(for app: MusicApp) -> String {
        switch self {
        case .notRunning: "\(app.name) isn’t running."
        case .permissionDenied: "Squidd needs permission to control \(app.name)."
        case .timedOut: "\(app.name) didn’t respond. Retrying shortly."
        case .nothingPlaying: "Nothing is loaded in \(app.name)."
        case .failed: "\(app.name) didn’t understand the request."
        }
    }

    /// Apple Event result codes Squidd can say something useful about.
    init(status: OSStatus) {
        switch status {
        case -1743: self = .permissionDenied            // errAEEventNotPermitted — Automation refused in Privacy.
        case -600, -609: self = .notRunning             // procNotFound / connectionInvalid.
        case -1712: self = .timedOut                    // errAETimeout.
        case -1728: self = .nothingPlaying              // errAENoSuchObject — no current track.
        default: self = .failed(status)
        }
    }
}

// MARK: - Apple Event plumbing

/// Raw Apple Events, deliberately not `NSAppleScript`. Measured on this machine: `NSAppleScript` costs ~62 ms a read
/// and **deadlocks** anywhere but the main thread (even on a thread with a run loop, and a stuck call takes the whole
/// process's AppleScript component down with it). Raw events run off the main actor and cost ~8 ms.
nonisolated enum AppleEvents {
    static func code(_ value: String) -> OSType {
        var result: OSType = 0
        for byte in value.utf8 { result = (result << 8) | OSType(byte) }
        return result
    }

    /// `<property> of <container>`, as an object specifier.
    static func property(_ property: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: code("prop"), form: code("prop"), data: NSAppleEventDescriptor(typeCode: property),
                  of: container)
    }

    /// `<class> <index> of <container>`, as an object specifier — `artwork 1 of current track`, say.
    static func element(_ elementClass: OSType, index: Int32,
                        of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: elementClass, form: code("indx"), data: NSAppleEventDescriptor(int32: index), of: container)
    }

    private static func specifier(want: OSType, form: OSType, data: NSAppleEventDescriptor,
                                  of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        // Force-unwrapped deliberately: this coercion is a fixed shape that cannot fail at runtime.
        return record.coerce(toDescriptorType: code("obj "))!
    }
}

/// Sends Apple Events to one app. Spotify and Apple Music share their player vocabulary — `player state`,
/// `player position`, `current track` and its `name`, `artist`, `album` and `duration` all use the same codes — so
/// the reads live here and each bridge adds only what differs.
nonisolated struct AppleEventClient: Sendable {
    let app: MusicApp
    let timeout: TimeInterval
    private static let log = Logger(subsystem: "com.squidd", category: "AppleEvents")

    /// How long the first event to an app may wait. macOS holds that event while its Automation prompt is on screen,
    /// so a short timeout expires before the user can click Allow. Once one event has been answered the bridges
    /// switch to `timeout`.
    static let firstContactTimeout: TimeInterval = 60

    func with(timeout: TimeInterval) -> AppleEventClient { AppleEventClient(app: app, timeout: timeout) }

    /// Addressed by bundle identifier rather than pid, so a relaunched app needs no rebinding.
    func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: AppleEvents.code(eventClass), eventID: AppleEvents.code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    func playerState() throws -> NowPlayingSnapshot.PlayState {
        let value = try get(AppleEvents.property(AppleEvents.code("pPlS"), of: .null()))
        // `player state` is an enumerator, not text: kPSP playing, kPSp paused, kPSS stopped. Apple Music adds
        // kPSF / kPSR for fast-forwarding and rewinding, which are still playing as far as the card is concerned.
        switch value.enumCodeValue {
        case AppleEvents.code("kPSP"), AppleEvents.code("kPSF"), AppleEvents.code("kPSR"): return .playing
        case AppleEvents.code("kPSp"): return .paused
        default: return .stopped
        }
    }

    func number(of property: String) throws -> Double {
        try get(AppleEvents.property(AppleEvents.code(property), of: .null())).doubleValue
    }

    var currentTrack: NSAppleEventDescriptor { AppleEvents.property(AppleEvents.code("pTrk"), of: .null()) }

    func trackProperty(_ property: String) throws -> NSAppleEventDescriptor {
        try get(AppleEvents.property(AppleEvents.code(property), of: currentTrack))
    }

    func trackText(_ property: String) throws -> String {
        guard let text = try trackProperty(property).stringValue else { throw PlayerBridgeError.nothingPlaying }
        return text
    }

    func trackNumber(_ property: String) throws -> Double {
        try trackProperty(property).doubleValue
    }

    func setPosition(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw PlayerBridgeError.failed(0) }
        let set = event("core", "setd")
        set.setParam(AppleEvents.property(AppleEvents.code("pPos"), of: .null()), forKeyword: AEKeyword(keyDirectObject))
        set.setParam(NSAppleEventDescriptor(double: seconds), forKeyword: AEKeyword(keyAEData))
        try perform(set)
    }

    func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let request = event("core", "getd")
        request.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        let reply = try perform(request)
        guard let value = reply?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            // A reply with no direct object means the app had nothing to give.
            throw PlayerBridgeError.nothingPlaying
        }
        return value
    }

    @discardableResult
    func perform(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            // A delivered event can still carry a refusal in its reply rather than throwing.
            if let failure = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, failure != 0 {
                throw failed(event, status: OSStatus(failure))
            }
            return reply
        } catch let error as PlayerBridgeError {
            throw error
        } catch let error as NSError {
            throw failed(event, status: OSStatus(error.code))
        }
    }

    /// Logs a refused or failed event — which app, which event, which property — so a problem reported from a real
    /// Mac can be traced with `log show --predicate 'subsystem == "com.squidd"'`.
    private func failed(_ event: NSAppleEventDescriptor, status: OSStatus) -> PlayerBridgeError {
        let name = { (code: OSType) in String(bytes: withUnsafeBytes(of: code.bigEndian, Array.init), encoding: .macOSRoman) ?? "?" }
        let property = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
            .forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
        Self.log.error("""
            \(app.name, privacy: .public) \(name(event.eventClass), privacy: .public)/\(name(event.eventID), privacy: .public) \
            \(property.map(name) ?? "-", privacy: .public) failed: \(status)
            """)
        return PlayerBridgeError(status: status)
    }
}

// MARK: - Automation permission

/// Whether macOS will let Squidd drive a music app. Checked without prompting, so Settings can describe the situation
/// and the prompt only appears when the user asks for it. Each app has its own permission.
nonisolated enum Automation {
    enum Permission: Equatable, Sendable { case granted, denied, notAsked, appNotRunning }

    static func permission(for app: MusicApp, askIfNeeded: Bool = false) -> Permission {
        guard app.isRunning else { return .appNotRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier)
        guard let descriptor = target.aeDesc else { return .notAsked }
        switch AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, askIfNeeded) {
        case noErr: return .granted
        case OSStatus(-1744): return .notAsked         // errAEEventWouldRequireUserConsent
        case OSStatus(-1743): return .denied           // errAEEventNotPermitted
        default: return .denied
        }
    }

    /// Privacy & Security ▸ Automation, for when permission was refused and only the user can undo that.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
