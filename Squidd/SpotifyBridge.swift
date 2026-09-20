import AppKit
import Carbon
import Foundation

nonisolated enum PlaybackCommand: Equatable, Sendable {
    case play, pause, previous, next, seek(Double)
}

/// What Squidd needs from whatever is playing music. Spotify is the only implementation today; Apple Music would be
/// a second one, since its scripting vocabulary is nearly identical.
protocol NowPlayingSource: Sendable {
    func snapshot() async throws -> SpotifyPlaybackSnapshot?
    /// Fetched on its own because it is the one field Spotify's notification leaves out.
    func artworkURL() async throws -> URL?
    func send(_ command: PlaybackCommand) async throws
}

// MARK: - Snapshot

/// One reading of Spotify's player. Built either from a `PlaybackStateChanged` notification (free, and how most
/// readings arrive) or from Apple Events (at launch, and as a safety net).
nonisolated struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    enum PlayState: Sendable, Equatable { case playing, paused, stopped }

    var state: PlayState = .stopped
    /// `spotify:track:…`, and also `spotify:ad:…` or `spotify:local:…`, which is how ads and local files are spotted.
    var trackID = ""
    var name = ""
    var artist = ""
    var album = ""
    var artworkURL: URL?
    var hasArtwork = false
    /// Spotify reports duration in **milliseconds**, though its scripting dictionary says seconds. Both the Apple
    /// Event and the notification agree on milliseconds; `duration` does the conversion.
    var durationMilliseconds: Double = 0
    /// Seconds — unlike `durationMilliseconds`. Spotify is inconsistent between the two, not Squidd.
    var positionSeconds: Double = 0

    var isPlaying: Bool { state == .playing }
    var isLoaded: Bool { !trackID.isEmpty && state != .stopped }
    var isAd: Bool { trackID.hasPrefix("spotify:ad:") }
    var isLocal: Bool { trackID.hasPrefix("spotify:local:") }

    var duration: Double { min(Double(Int32.max) / 1000, max(0, durationMilliseconds / 1000)) }
    var elapsed: Double { min(duration, max(0, positionSeconds)) }
    var identity: String { trackID.isEmpty ? "idle" : trackID }
    var title: String {
        if isAd { return "Advertisement" }
        if !name.isEmpty { return name }
        return isPlaying ? "Playback unavailable" : "Nothing playing"
    }

    /// Spotify's scripting interface exposes no equivalent of the Web API's `disallows`, so anything loaded and not
    /// an ad is fair game; Spotify simply ignores a command it cannot honor.
    func permits(_ command: PlaybackCommand) -> Bool {
        guard isLoaded, !isAd else { return false }
        if case .seek = command { return duration > 0 }
        return true
    }
}

extension SpotifyPlaybackSnapshot {
    /// Keys Spotify puts in its `PlaybackStateChanged` notification. Verified live; `userInfo` survives the App
    /// Sandbox intact, so a state change needs no Apple Event at all.
    init?(notification userInfo: [AnyHashable: Any]) {
        guard let rawState = userInfo["Player State"] as? String else { return nil }
        switch rawState {
        case "Playing": state = .playing
        case "Paused": state = .paused
        default: state = .stopped
        }
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
}

// MARK: - Errors

nonisolated enum SpotifyBridgeError: Error, LocalizedError, Equatable {
    case notRunning
    case permissionDenied
    case timedOut
    case nothingPlaying
    case failed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Spotify isn’t running."
        case .permissionDenied: "Squidd needs permission to control Spotify."
        case .timedOut: "Spotify didn’t respond. Retrying shortly."
        case .nothingPlaying: "Nothing is loaded in Spotify."
        case .failed: "Spotify didn’t understand the request."
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
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: property), forKeyword: AEKeyword(keyAEKeyData))
        // Force-unwrapped deliberately: this coercion is a fixed shape that cannot fail at runtime.
        return record.coerce(toDescriptorType: code("obj "))!
    }
}

/// Talks to the Spotify app over Apple Events. An actor, so the sends serialize and stay off the main thread.
actor SpotifyEventBridge: NowPlayingSource {
    nonisolated static let bundleIdentifier = "com.spotify.client"

    private let timeout: TimeInterval
    /// Which app to address. Held as a bundle identifier rather than a pid so a relaunched Spotify needs no rebinding.
    private var target: NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
    }

    init(timeout: TimeInterval = 2) { self.timeout = max(0.1, timeout) }

    /// Spotify is only addressed while it is already running — addressing a stopped app would launch it, and Squidd
    /// opening Spotify on its own would be a surprise.
    nonisolated static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func snapshot() async throws -> SpotifyPlaybackSnapshot? {
        guard Self.isSpotifyRunning else { throw SpotifyBridgeError.notRunning }
        var snapshot = SpotifyPlaybackSnapshot()
        snapshot.state = try playerState()
        // Stopped means nothing is loaded; the remaining reads would only fail.
        guard snapshot.state != .stopped else { return snapshot }
        snapshot.positionSeconds = (try? number(of: "pPos")) ?? 0
        do {
            snapshot.trackID = try trackText("ID  ")
            snapshot.name = try trackText("pnam")
            snapshot.artist = try trackText("pArt")
            snapshot.album = try trackText("pAlb")
            snapshot.durationMilliseconds = try trackNumber("pDur")
            let artwork = (try? trackText("aUrl")) ?? ""
            snapshot.artworkURL = URL(string: artwork)
            snapshot.hasArtwork = snapshot.artworkURL != nil
        } catch SpotifyBridgeError.nothingPlaying {
            // Spotify says it is playing but exposes no track: an ad or a gap between tracks.
            return snapshot
        }
        return snapshot
    }

    /// Fetches only the artwork URL. This is the one field the notification omits, so it is the one Apple Event a
    /// running Squidd makes in normal use — once per track change.
    func artworkURL() async throws -> URL? {
        guard Self.isSpotifyRunning else { throw SpotifyBridgeError.notRunning }
        guard let text = try? trackText("aUrl") else { return nil }
        return URL(string: text)
    }

    func send(_ command: PlaybackCommand) async throws {
        guard Self.isSpotifyRunning else { throw SpotifyBridgeError.notRunning }
        switch command {
        case .play: try perform(event("spfy", "Play"))
        case .pause: try perform(event("spfy", "Paus"))
        case .next: try perform(event("spfy", "Next"))
        case .previous: try perform(event("spfy", "Prev"))
        case .seek(let seconds):
            guard seconds.isFinite, seconds >= 0 else { throw SpotifyBridgeError.failed(0) }
            let set = event("core", "setd")
            set.setParam(AppleEvents.property(AppleEvents.code("pPos"), of: .null()),
                         forKeyword: AEKeyword(keyDirectObject))
            set.setParam(NSAppleEventDescriptor(double: seconds), forKeyword: AEKeyword(keyAEData))
            try perform(set)
        }
    }

    // MARK: Reads

    private func playerState() throws -> SpotifyPlaybackSnapshot.PlayState {
        let value = try get(AppleEvents.property(AppleEvents.code("pPlS"), of: .null()))
        // `player state` is an enumerator, not text: kPSP playing, kPSp paused, kPSS stopped.
        switch value.enumCodeValue {
        case AppleEvents.code("kPSP"): return .playing
        case AppleEvents.code("kPSp"): return .paused
        default: return .stopped
        }
    }

    private func number(of property: String) throws -> Double {
        try get(AppleEvents.property(AppleEvents.code(property), of: .null())).doubleValue
    }

    private func trackProperty(_ property: String) throws -> NSAppleEventDescriptor {
        let track = AppleEvents.property(AppleEvents.code("pTrk"), of: .null())
        return try get(AppleEvents.property(AppleEvents.code(property), of: track))
    }

    private func trackText(_ property: String) throws -> String {
        guard let text = try trackProperty(property).stringValue else { throw SpotifyBridgeError.nothingPlaying }
        return text
    }

    private func trackNumber(_ property: String) throws -> Double {
        try trackProperty(property).doubleValue
    }

    // MARK: Sending

    private func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: AppleEvents.code(eventClass), eventID: AppleEvents.code(eventID),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }

    private func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let request = event("core", "getd")
        request.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        let reply = try perform(request)
        guard let value = reply?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            // A reply with no direct object means Spotify had nothing to give.
            throw SpotifyBridgeError.nothingPlaying
        }
        return value
    }

    @discardableResult
    private func perform(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            // A delivered event can still carry a refusal in its reply rather than throwing.
            if let failure = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, failure != 0 {
                throw SpotifyBridgeError(status: OSStatus(failure))
            }
            return reply
        } catch let error as SpotifyBridgeError {
            throw error
        } catch let error as NSError {
            throw SpotifyBridgeError(status: OSStatus(error.code))
        }
    }
}

// MARK: - Automation permission

/// Whether macOS will let Squidd drive Spotify. Checked without prompting, so Settings can describe the situation and
/// the prompt only appears when the user asks for it.
nonisolated enum SpotifyAutomation {
    enum Permission: Equatable, Sendable { case granted, denied, notAsked, spotifyNotRunning }

    static func permission(askIfNeeded: Bool = false) -> Permission {
        guard SpotifyEventBridge.isSpotifyRunning else { return .spotifyNotRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyEventBridge.bundleIdentifier)
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
