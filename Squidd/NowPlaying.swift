import AppKit
import Carbon
import Foundation
import os

nonisolated enum PlaybackCommand: Equatable, Sendable {
    case play, pause, previous, next, seek(Double)
}

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

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

protocol NowPlayingSource: Sendable {
    func snapshot() async throws -> NowPlayingSnapshot?
    func artwork(for trackID: String) async throws -> ArtworkReference?
    func send(_ command: PlaybackCommand) async throws
}

nonisolated enum ArtworkReference: Equatable, Sendable {
    case remote(URL)
    case embedded(key: String, data: Data)

    var key: String {
        switch self {
        case .remote(let url): url.absoluteString
        case .embedded(let key, _): key
        }
    }
}

nonisolated struct NowPlayingSnapshot: Equatable, Sendable {
    enum PlayState: Sendable, Equatable { case playing, paused, stopped }

    var app: MusicApp = .spotify
    var state: PlayState = .stopped
    var trackID = ""
    var name = ""
    var artist = ""
    var album = ""
    var artworkURL: URL?
    var hasArtwork = false
    var durationMilliseconds: Double = 0
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

    func permits(_ command: PlaybackCommand) -> Bool {
        guard isLoaded, !isAd else { return false }
        if case .seek = command { return duration > 0 }
        return true
    }

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

    init?(spotifyNotification userInfo: [AnyHashable: Any]) {
        guard let state = Self.playState(userInfo) else { return nil }
        self.state = state
        trackID = userInfo["Track ID"] as? String ?? ""
        name = userInfo["Name"] as? String ?? ""
        artist = userInfo["Artist"] as? String ?? ""
        album = userInfo["Album"] as? String ?? ""
        durationMilliseconds = (userInfo["Duration"] as? NSNumber)?.doubleValue ?? 0
        positionSeconds = (userInfo["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        hasArtwork = ((userInfo["Has Artwork"] as? NSNumber)?.boolValue ?? false)
    }

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

    init(status: OSStatus) {
        switch status {
        case -1743: self = .permissionDenied
        case -600, -609: self = .notRunning
        case -1712: self = .timedOut
        case -1728: self = .nothingPlaying
        default: self = .failed(status)
        }
    }
}

nonisolated enum AppleEvents {
    static func code(_ value: String) -> OSType {
        var result: OSType = 0
        for byte in value.utf8 { result = (result << 8) | OSType(byte) }
        return result
    }

    static func property(_ property: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: code("prop"), form: code("prop"), data: NSAppleEventDescriptor(typeCode: property),
                  of: container)
    }

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
        return record.coerce(toDescriptorType: code("obj "))!
    }
}

nonisolated struct AppleEventClient: Sendable {
    let app: MusicApp
    let timeout: TimeInterval
    private static let log = Logger(subsystem: "com.squidd", category: "AppleEvents")

    static let firstContactTimeout: TimeInterval = 60

    func with(timeout: TimeInterval) -> AppleEventClient { AppleEventClient(app: app, timeout: timeout) }

    func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: AppleEvents.code(eventClass), eventID: AppleEvents.code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    func playerState() throws -> NowPlayingSnapshot.PlayState {
        let value = try get(AppleEvents.property(AppleEvents.code("pPlS"), of: .null()))
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
            throw PlayerBridgeError.nothingPlaying
        }
        return value
    }

    @discardableResult
    func perform(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
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

nonisolated enum Automation {
    enum Permission: Equatable, Sendable { case granted, denied, notAsked, appNotRunning }

    static func permission(for app: MusicApp, askIfNeeded: Bool = false) -> Permission {
        guard app.isRunning else { return .appNotRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier)
        guard let descriptor = target.aeDesc else { return .notAsked }
        switch AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, askIfNeeded) {
        case noErr: return .granted
        case OSStatus(-1744): return .notAsked
        case OSStatus(-1743): return .denied
        default: return .denied
        }
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
