import AppKit
import Foundation

actor EmptyArtwork: ArtworkLoading {
    func image(for artwork: ArtworkReference) async throws -> CGImage { throw URLError(.cannotDecodeContentData) }
}

@MainActor
final class HeldArtwork: ArtworkLoading {
    var pending: [String: CheckedContinuation<CGImage, Error>] = [:]
    var requested: [String] = []
    func image(for artwork: ArtworkReference) async throws -> CGImage {
        requested.append(artwork.key)
        return try await withCheckedThrowingContinuation { pending[artwork.key] = $0 }
    }
    func complete(_ key: String, image: CGImage) { pending.removeValue(forKey: key)?.resume(returning: image) }
}

@MainActor
final class TestSource: NowPlayingSource {
    var next: Result<NowPlayingSnapshot?, Error> = .success(nil)
    var artwork: Result<ArtworkReference?, Error> = .success(nil)
    var held: CheckedContinuation<NowPlayingSnapshot?, Error>?
    var holdNext = false
    var commandFailure: Error?
    var sent: [PlaybackCommand] = []
    var reads = 0
    var artworkReads = 0
    var active = 0
    var maximumActive = 0

    func snapshot() async throws -> NowPlayingSnapshot? {
        reads += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdNext { holdNext = false; return try await withCheckedThrowingContinuation { held = $0 } }
        return try next.get()
    }
    func artwork(for trackID: String) async throws -> ArtworkReference? {
        artworkReads += 1
        return try artwork.get()
    }
    func send(_ command: PlaybackCommand) async throws {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        sent.append(command)
        if let commandFailure { throw commandFailure }
    }
    func release(_ result: Result<NowPlayingSnapshot?, Error>) { let p = held; held = nil; p?.resume(with: result) }
}

@main
struct SpotifyPlaybackChecks {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Playback check timed out")
    }

    static func sample(id: String = "spotify:track:one", playing: Bool = true, position: Double = 10,
                       durationMilliseconds: Double = 200_000, artwork: String? = nil) -> NowPlayingSnapshot {
        var snapshot = NowPlayingSnapshot()
        snapshot.state = playing ? .playing : .paused
        snapshot.trackID = id
        snapshot.name = "Track"
        snapshot.artist = "Test artist"
        snapshot.album = "Test album"
        snapshot.durationMilliseconds = durationMilliseconds
        snapshot.positionSeconds = position
        snapshot.artworkURL = artwork.flatMap { URL(string: $0) }
        snapshot.hasArtwork = snapshot.artworkURL != nil
        return snapshot
    }

    static func broadcast(state: String = "Playing", id: String = "spotify:track:one", name: String = "Juno",
                          position: Double = 126.39, duration: Int = 223_192,
                          artwork: Int = 1) -> [AnyHashable: Any] {
        ["Player State": state, "Track ID": id, "Name": name, "Artist": "Sabrina Carpenter",
         "Album": "Short n' Sweet", "Album Artist": "Sabrina Carpenter", "Duration": duration,
         "Playback Position": position, "Has Artwork": artwork, "Track Number": 10, "Disc Number": 1,
         "Popularity": 83, "Play Count": 0]
    }

    static func musicBroadcast(state: String = "Playing", persistentID: Int64 = 0x1A2B3C4D5E6F7081,
                               name: String = "Blinding Lights", totalTime: Int = 200_040) -> [AnyHashable: Any] {
        ["Player State": state, "PersistentID": NSNumber(value: persistentID), "Name": name, "Artist": "The Weeknd",
         "Album": "After Hours", "Album Artist": "The Weeknd", "Total Time": totalTime, "Genre": "R&B/Soul",
         "Track Number": 9, "Track Count": 14, "Store URL": "itms://itunes.apple.com/album/1499378108"]
    }

    static func musicSample(id: Int64 = 0x1A2B3C4D5E6F7081, playing: Bool = true, position: Double = 42,
                            name: String = "Blinding Lights") -> NowPlayingSnapshot {
        var snapshot = sample(id: NowPlayingSnapshot.musicTrackID(UInt64(bitPattern: id)), playing: playing,
                              position: position)
        snapshot.app = .music
        snapshot.name = name
        snapshot.hasArtwork = true
        return snapshot
    }

    @MainActor
    static func playback(spotify: TestSource, music: TestSource, images: (any ArtworkLoading)? = nil,
                         running: @escaping (MusicApp) -> Bool = { _ in true }) -> Playback {
        Playback(sources: [.spotify: spotify, .music: music], isRunning: running, isPermitted: { _ in true },
                 images: images ?? EmptyArtwork(), pollInterval: 30, idlePollInterval: 30, boostInterval: 0.02,
                 reconciliationDelay: 0, observeNotifications: false)
    }

    @MainActor
    static func playback(_ source: TestSource, images: (any ArtworkLoading)? = nil,
                         pollInterval: Double = 0.05, idlePollInterval: Double? = nil,
                         backgroundPollInterval: Double? = nil, boostInterval: Double = 0.02,
                         reconciliationDelay: Double = 0) -> Playback {
        Playback(source: source, images: images ?? EmptyArtwork(), pollInterval: pollInterval,
                        idlePollInterval: idlePollInterval, backgroundPollInterval: backgroundPollInterval,
                        boostInterval: boostInterval, reconciliationDelay: reconciliationDelay,
                        observeNotifications: false)
    }

    @MainActor static func main() async throws {
        try checkSnapshotValues()
        try checkNotificationParsing()
        try checkErrorMapping()
        try await checkInitialReadAndCommands()
        try await checkNotificationDrivesUpdates()
        try await checkArtworkFetchedOncePerTrack()
        try await checkSeekRollback()
        try await checkFailureStates()
        try await checkPreviewAndSuspend()
        try checkMusicNotificationParsing()
        try await checkMusicPositionAndArtwork()
        try await checkFollowsWhicheverAppPlays()
        try await checkFollowsOpenAppWhenOneQuits()
        print("Playback checks passed: Spotify, Apple Music, and following whichever one plays")
        if CommandLine.arguments.contains("--integration") {
            try await checkAgainstRealSpotify()
            try await checkAgainstRealMusic()
        }
    }

    @MainActor static func checkAgainstRealSpotify() async throws {
        guard MusicApp.spotify.isRunning else {
            print("Integration checks skipped: Spotify isn't running")
            return
        }
        let permission = Automation.permission(for: .spotify)
        guard permission == .granted else {
            print("Integration checks skipped: Automation permission is \(permission)")
            return
        }
        let bridge = SpotifyEventBridge()
        guard let snapshot = try await bridge.snapshot() else { fatalError("A running Spotify should report state") }
        guard snapshot.isLoaded else {
            print("Integration checks skipped: Spotify is open but nothing is loaded")
            return
        }
        assert(!snapshot.name.isEmpty, "A loaded track should have a name")
        assert(snapshot.trackID.hasPrefix("spotify:"), "Track ID should be a Spotify URI, got \(snapshot.trackID)")
        assert(snapshot.duration > 1 && snapshot.duration < 24 * 3600,
               "Duration looks wrong in seconds: \(snapshot.duration) — is Spotify still reporting milliseconds?")
        assert((snapshot.positionSeconds ?? 0) <= snapshot.duration + 1, "Position should fall within the track")

        let artwork = try await bridge.artwork(for: snapshot.trackID)
        if snapshot.hasArtwork {
            guard case .remote(let url) = artwork, url.scheme == "https" else {
                fatalError("Artwork should be an https URL, got \(String(describing: artwork))")
            }
        }

        let wasPlaying = snapshot.isPlaying
        try await bridge.send(wasPlaying ? .pause : .play)
        try await Task.sleep(for: .milliseconds(400))
        let flipped = try await bridge.snapshot()
        assert(flipped?.isPlaying == !wasPlaying, "Play/pause should change the reported state")
        try await bridge.send(wasPlaying ? .play : .pause)
        try await Task.sleep(for: .milliseconds(400))

        if let now = try await bridge.snapshot()?.elapsed, now > 0 {
            try await bridge.send(.seek(now))
        }
        print("Integration checks passed against the running Spotify: '\(snapshot.name)' by \(snapshot.artist)")
    }

    @MainActor static func checkAgainstRealMusic() async throws {
        guard MusicApp.music.isRunning else {
            print("Apple Music integration checks skipped: Music isn't running")
            return
        }
        let permission = Automation.permission(for: .music)
        guard permission == .granted else {
            print("Apple Music integration checks skipped: Automation permission is \(permission)")
            return
        }
        let bridge = AppleMusicEventBridge()
        guard let snapshot = try await bridge.snapshot(), snapshot.isLoaded else {
            print("Apple Music integration checks skipped: Music is open but nothing is loaded")
            return
        }
        assert(snapshot.app == .music && snapshot.trackID.hasPrefix("music:"), "Got \(snapshot.trackID)")
        assert(!snapshot.name.isEmpty, "A loaded track should have a name")
        assert(snapshot.duration == 0 || (snapshot.duration > 1 && snapshot.duration < 24 * 3600),
               "Duration looks wrong in seconds: \(snapshot.duration)")
        assert((snapshot.positionSeconds ?? 0) <= snapshot.duration + 1 || snapshot.duration == 0)

        let artwork = try await bridge.artwork(for: snapshot.trackID)
        if case .embedded(_, let data) = artwork {
            let image = try await ArtworkCache().image(for: artwork!)
            print("Apple Music artwork: \(data.count) bytes, decoded to \(image.width)×\(image.height)")
        } else {
            print("Apple Music artwork: none for this track")
        }

        final class Inbox: @unchecked Sendable { var userInfo: [AnyHashable: Any]? }
        let inbox = Inbox()
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: MusicApp.music.broadcast, object: nil, queue: .main) { inbox.userInfo = $0.userInfo }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        let wasPlaying = snapshot.isPlaying
        try await bridge.send(wasPlaying ? .pause : .play)
        try await Task.sleep(for: .milliseconds(600))
        let flipped = try await bridge.snapshot()
        assert(flipped?.isPlaying == !wasPlaying, "Play/pause should change the reported state")
        try await bridge.send(wasPlaying ? .play : .pause)
        try await Task.sleep(for: .milliseconds(600))
        if let received = inbox.userInfo {
            let keys = received.keys.map { "\($0)" }.sorted().joined(separator: ", ")
            print("Apple Music broadcast keys: \(keys)")
            let parsed = NowPlayingSnapshot(musicNotification: received)
            assert(parsed?.trackID == snapshot.trackID,
                   "Broadcast and Apple Event IDs should match: \(parsed?.trackID ?? "nil") vs \(snapshot.trackID)")
        } else {
            print("Apple Music broadcast: none arrived — Squidd would rely on the safety-net poll")
        }
        if let now = try await bridge.snapshot()?.elapsed, now > 0 { try await bridge.send(.seek(now)) }
        print("Integration checks passed against the running Music: '\(snapshot.name)' by \(snapshot.artist)")
    }

    @MainActor static func checkSnapshotValues() throws {
        let track = sample()
        assert(track.duration == 200, "duration should convert milliseconds to seconds")
        assert(track.elapsed == 10)
        assert(track.identity == "spotify:track:one")
        assert(track.title == "Track")
        assert(track.isLoaded && track.isPlaying && !track.isAd && !track.isLocal)
        assert(track.permits(.play) && track.permits(.next) && track.permits(.seek(10)))

        let overrun = sample(position: 500)
        assert(overrun.elapsed == 200)

        var ad = sample(id: "spotify:ad:abc")
        ad.name = ""
        assert(ad.isAd && ad.title == "Advertisement")
        assert(!ad.permits(.play) && !ad.permits(.next) && !ad.permits(.seek(1)))

        let local = sample(id: "spotify:local:something")
        assert(local.isLocal && local.artworkURL == nil && local.permits(.seek(1)))

        var stopped = NowPlayingSnapshot()
        stopped.state = .stopped
        assert(!stopped.isLoaded && stopped.title == "Nothing playing" && stopped.identity == "idle")
        assert(!stopped.permits(.play))

        var blank = NowPlayingSnapshot()
        blank.state = .playing
        assert(blank.title == "Playback unavailable")

        let unknownLength = sample(durationMilliseconds: 0)
        assert(unknownLength.duration == 0 && !unknownLength.permits(.seek(1)) && unknownLength.permits(.play))
    }

    @MainActor static func checkNotificationParsing() throws {
        guard let parsed = NowPlayingSnapshot(spotifyNotification: broadcast()) else {
            fatalError("A well-formed broadcast should parse")
        }
        assert(parsed.isPlaying && parsed.trackID == "spotify:track:one")
        assert(parsed.name == "Juno" && parsed.artist == "Sabrina Carpenter" && parsed.album == "Short n' Sweet")
        assert(abs(parsed.duration - 223.192) < 0.001, "Duration arrives in milliseconds here too")
        assert(abs(parsed.elapsed - 126.39) < 0.001, "Playback Position arrives in seconds")
        assert(parsed.hasArtwork)

        let paused = NowPlayingSnapshot(spotifyNotification: broadcast(state: "Paused"))
        assert(paused?.isPlaying == false && paused?.isLoaded == true)

        let stopped = NowPlayingSnapshot(spotifyNotification: broadcast(state: "Stopped"))
        assert(stopped?.isLoaded == false)

        assert(NowPlayingSnapshot(spotifyNotification: ["Name": "Juno"]) == nil)

        let sparse = NowPlayingSnapshot(spotifyNotification: ["Player State": "Playing"])
        assert(sparse?.name == "" && sparse?.duration == 0 && sparse?.isLoaded == false)

        let artless = NowPlayingSnapshot(spotifyNotification: broadcast(artwork: 0))
        assert(artless?.hasArtwork == false)

        let awkward = NowPlayingSnapshot(spotifyNotification: broadcast(name: "a|b\u{1}c — “quoted” 🎧"))
        assert(awkward?.name == "a|b\u{1}c — “quoted” 🎧")

        let ad = NowPlayingSnapshot(spotifyNotification: broadcast(id: "spotify:ad:xyz", name: "Some Ad"))
        assert(ad?.isAd == true && ad?.title == "Advertisement" && ad?.permits(.next) == false)
    }

    @MainActor static func checkErrorMapping() throws {
        assert(PlayerBridgeError(status: -1743) == .permissionDenied)
        assert(PlayerBridgeError(status: -600) == .notRunning)
        assert(PlayerBridgeError(status: -609) == .notRunning)
        assert(PlayerBridgeError(status: -1712) == .timedOut)
        assert(PlayerBridgeError(status: -1728) == .nothingPlaying)
        assert(PlayerBridgeError(status: -1701) == .failed(-1701))
        assert(PlayerBridgeError.notRunning.description(for: .spotify).contains("Spotify"))
        assert(PlayerBridgeError.notRunning.description(for: .music).contains("Apple Music"))
    }

    @MainActor static func checkInitialReadAndCommands() async throws {
        let source = TestSource()
        source.next = .success(sample())
        let playback = playback(source)
        defer { playback.stop() }

        try await waitUntil { playback.state == .playing }
        assert(playback.title == "Track" && playback.duration == 200)
        assert(source.reads >= 1)

        source.next = .success(sample(playing: false))
        playback.send(.pause)
        playback.send(.pause)
        playback.send(.next)
        try await waitUntil { !playback.busy }
        assert(source.sent == [.pause], "A second command while one is in flight should be dropped")
        assert(source.maximumActive == 1, "Reads and commands must not overlap")
        try await waitUntil { playback.state == .paused }

        source.holdNext = true
        playback.boost(for: 0.05)
        try await waitUntil { source.held != nil }
        playback.send(.play)
        source.release(.success(sample(id: "spotify:track:stale", playing: false)))
        try await waitUntil { !playback.busy }
        assert(playback.identity != "spotify:track:stale", "A stale read should be discarded")
    }

    @MainActor static func checkNotificationDrivesUpdates() async throws {
        let source = TestSource()
        source.next = .success(nil)
        let playback = playback(source, pollInterval: 30, idlePollInterval: 30)
        defer { playback.stop() }
        try await waitUntil { playback.state == .idle }
        let readsBefore = source.reads

        playback.receive(notification: broadcast())
        assert(playback.state == .playing)
        assert(playback.title == "Juno" && playback.artist == "Sabrina Carpenter")
        assert(abs(playback.duration - 223.192) < 0.001)
        assert(abs(playback.elapsed - 126.39) < 0.001)
        assert(source.reads == readsBefore, "A broadcast must not trigger a snapshot read")

        playback.receive(notification: broadcast(state: "Paused", position: 130))
        assert(playback.state == .paused && !playback.isPlaying)

        playback.receive(notification: broadcast(state: "Stopped"))
        assert(playback.state == .idle && playback.snapshot?.isLoaded == false)

        playback.receive(notification: broadcast())
        let before = playback.identity
        playback.receive(notification: ["Name": "nonsense"])
        assert(playback.identity == before)
    }

    @MainActor static func checkArtworkFetchedOncePerTrack() async throws {
        let source = TestSource()
        let images = HeldArtwork()
        source.next = .success(nil)
        source.artwork = .success(.remote(URL(string: "https://i.scdn.co/image/one")!))
        let playback = playback(source, images: images, pollInterval: 30, idlePollInterval: 30)
        defer { playback.stop() }
        try await waitUntil { playback.state == .idle }

        playback.receive(notification: broadcast())
        try await waitUntil { source.artworkReads == 1 }
        try await waitUntil { playback.artworkKey == "https://i.scdn.co/image/one" }

        playback.receive(notification: broadcast(state: "Paused"))
        playback.receive(notification: broadcast(position: 130))
        try await Task.sleep(for: .milliseconds(80))
        assert(source.artworkReads == 1, "Artwork should be fetched once per track, not per broadcast")

        source.artwork = .success(.remote(URL(string: "https://i.scdn.co/image/two")!))
        playback.receive(notification: broadcast(id: "spotify:track:two", name: "Espresso"))
        try await waitUntil { source.artworkReads == 2 }
        try await waitUntil { playback.artworkKey == "https://i.scdn.co/image/two" }

        playback.receive(notification: broadcast(id: "spotify:track:three", artwork: 0))
        try await waitUntil { playback.artworkKey == "idle" }
        assert(source.artworkReads == 2, "No artwork means no lookup")

        assert(playback.loadedArtworkKey == "idle")

        source.artwork = .failure(PlayerBridgeError.timedOut)
        playback.receive(notification: broadcast(id: "spotify:track:four"))
        try await waitUntil { source.artworkReads == 3 }
        source.artwork = .success(.remote(URL(string: "https://i.scdn.co/image/four")!))
        playback.receive(notification: broadcast(state: "Paused", id: "spotify:track:four"))
        try await waitUntil { source.artworkReads == 4 }
        try await waitUntil { playback.artworkKey == "https://i.scdn.co/image/four" }
    }

    @MainActor static func checkSeekRollback() async throws {
        let source = TestSource()
        source.next = .success(sample(position: 10))
        let playback = playback(source, pollInterval: 30, idlePollInterval: 30)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }

        source.commandFailure = PlayerBridgeError.timedOut
        playback.send(.seek(120))
        assert(abs(playback.elapsed - 120) < 0.001)
        try await waitUntil { !playback.busy }
        assert(abs(playback.elapsed - 10) < 1, "A failed seek should roll back")
        assert(playback.state == .commandError)

        source.commandFailure = nil
        playback.retry()
        try await waitUntil { playback.state == .playing }
        playback.send(.seek(9999))
        try await waitUntil { !playback.busy }
        assert(source.sent.contains(.seek(200)), "Seek should clamp to the duration")
    }

    @MainActor static func checkFailureStates() async throws {
        let closed = TestSource()
        closed.next = .failure(PlayerBridgeError.notRunning)
        let first = playback(closed)
        try await waitUntil { first.state == .notRunning }
        assert(first.needsAttention && first.snapshot == nil && first.artworkKey == "idle")
        assert(!first.offers(.play))
        first.stop()

        let denied = TestSource()
        denied.next = .failure(PlayerBridgeError.permissionDenied)
        let second = playback(denied)
        try await waitUntil { second.state == .permissionDenied || second.state == .permissionNeeded }
        assert(second.needsAttention)
        assert(second.message?.isEmpty == false)
        let reads = denied.reads
        try await Task.sleep(for: .milliseconds(150))
        assert(denied.reads == reads, "A refusal should not be retried on the poll interval")
        second.stop()

        let empty = TestSource()
        empty.next = .failure(PlayerBridgeError.nothingPlaying)
        let third = playback(empty)
        try await waitUntil { third.state == .idle }
        assert(!third.needsAttention)
        third.stop()

        let flaky = TestSource()
        flaky.next = .failure(PlayerBridgeError.timedOut)
        let fourth = playback(flaky)
        defer { fourth.stop() }
        try await waitUntil { fourth.state == .offline }
        flaky.next = .success(sample())
        fourth.retry()
        try await waitUntil { fourth.state == .playing }
    }

    @MainActor static func checkPreviewAndSuspend() async throws {
        let source = TestSource()
        source.next = .success(sample())
        let playback = playback(source)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }

        playback.setPreviewing(true)
        try await Task.sleep(for: .milliseconds(60))
        let duringPreview = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == duringPreview, "Preview must generate no Spotify traffic")
        assert(playback.snapshot == nil && !playback.offers(.play))
        playback.receive(notification: broadcast())
        assert(playback.snapshot == nil)

        playback.setPreviewing(false)
        try await waitUntil { playback.state == .playing }

        playback.setSuspended(true)
        try await Task.sleep(for: .milliseconds(60))
        let duringSleep = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == duringSleep, "Nothing should be read while nobody can see the widget")
        playback.setSuspended(false)
        try await waitUntil { playback.state == .playing }

        playback.stop()
        let afterStop = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == afterStop)
    }

    @MainActor static func checkMusicNotificationParsing() throws {
        guard let parsed = NowPlayingSnapshot(notification: musicBroadcast(), from: .music) else {
            fatalError("A well-formed Music broadcast should parse")
        }
        assert(parsed.app == .music && parsed.isPlaying && parsed.isLoaded)
        assert(parsed.name == "Blinding Lights" && parsed.artist == "The Weeknd" && parsed.album == "After Hours")
        assert(abs(parsed.duration - 200.04) < 0.001, "Total Time arrives in milliseconds")
        assert(parsed.positionSeconds == nil, "Music's broadcast has no position, and must not pretend to")
        assert(parsed.hasArtwork, "No artwork flag in the broadcast, so a loaded track is always worth one lookup")
        assert(!parsed.isAd && parsed.permits(.previous) && parsed.permits(.seek(1)))

        assert(parsed.trackID == "music:1A2B3C4D5E6F7081")
        assert(NowPlayingSnapshot.musicTrackID(hex: "1a2b3c4d5e6f7081") == parsed.trackID)
        let negative = NowPlayingSnapshot(musicNotification: musicBroadcast(persistentID: -2))
        assert(negative?.trackID == "music:FFFFFFFFFFFFFFFE")
        assert(NowPlayingSnapshot.musicTrackID(hex: "FFFFFFFFFFFFFFFE") == negative?.trackID)
        assert(NowPlayingSnapshot.musicTrackID(hex: "00000000000000FF") == NowPlayingSnapshot.musicTrackID(255))

        let paused = NowPlayingSnapshot(musicNotification: musicBroadcast(state: "Paused"))
        assert(paused?.isPlaying == false && paused?.isLoaded == true)
        let stopped = NowPlayingSnapshot(musicNotification: ["Player State": "Stopped"])
        assert(stopped?.isLoaded == false && stopped?.hasArtwork == false)
        assert(NowPlayingSnapshot(musicNotification: ["Name": "x"]) == nil)
    }

    @MainActor static func checkMusicPositionAndArtwork() async throws {
        let music = TestSource()
        let images = HeldArtwork()
        music.next = .success(musicSample(position: 42))
        music.artwork = .success(.embedded(key: "music:1A2B3C4D5E6F7081#artwork", data: Data([1, 2, 3])))
        let playback = Playback(source: nil, sources: [.music: music], images: images, pollInterval: 30,
                                idlePollInterval: 30, boostInterval: 0.02, reconciliationDelay: 0,
                                observeNotifications: false)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }
        assert(playback.app == .music && playback.status == "Playing on Apple Music")
        assert(abs(playback.elapsed - 42) < 1)
        try await waitUntil { music.artworkReads == 1 && playback.artworkKey == "music:1A2B3C4D5E6F7081#artwork" }

        let readsBefore = music.reads
        music.next = .success(musicSample(playing: false, position: 43))
        playback.receive(notification: musicBroadcast(state: "Paused"), from: .music)
        assert(playback.state == .paused && playback.elapsed > 40, "Same track: the position carries over")
        try await waitUntil { music.reads > readsBefore }
        try await waitUntil { abs(playback.elapsed - 43) < 0.01 }
        assert(music.artworkReads == 1, "Same track: no second artwork lookup")

        music.next = .success(musicSample(id: 99, position: 5, name: "Save Your Tears"))
        playback.receive(notification: musicBroadcast(persistentID: 99, name: "Save Your Tears"), from: .music)
        assert(playback.title == "Save Your Tears" && playback.elapsed < 1)
        try await waitUntil { abs(playback.elapsed - 5) < 0.5 }
        try await waitUntil { music.artworkReads == 2 }

        playback.send(.previous)
        try await waitUntil { !playback.busy }
        assert(music.sent == [.previous])
    }

    @MainActor static func checkFollowsWhicheverAppPlays() async throws {
        let spotify = TestSource(), music = TestSource()
        spotify.next = .success(sample())
        music.next = .success(musicSample(playing: false))
        let playback = playback(spotify: spotify, music: music)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }
        assert(playback.app == .spotify && playback.title == "Track")

        playback.receive(notification: musicBroadcast(state: "Paused"), from: .music)
        playback.receive(notification: ["Player State": "Stopped"], from: .music)
        assert(playback.app == .spotify && playback.title == "Track")

        music.next = .success(musicSample())
        playback.receive(notification: musicBroadcast(), from: .music)
        assert(playback.app == .music && playback.title == "Blinding Lights" && playback.state == .playing)
        playback.send(.next)
        try await waitUntil { !playback.busy }
        assert(music.sent == [.next] && spotify.sent.isEmpty, "Commands go to the app the card shows")

        music.next = .success(musicSample(playing: false))
        playback.receive(notification: musicBroadcast(state: "Paused"), from: .music)
        spotify.next = .success(sample(playing: false))
        playback.receive(notification: broadcast(state: "Paused"))
        assert(playback.app == .music && playback.state == .paused)

        spotify.next = .success(sample())
        playback.receive(notification: broadcast())
        assert(playback.app == .spotify && playback.title == "Juno")

        spotify.next = .success(sample(playing: false))
        music.next = .success(musicSample())
        playback.boost(for: 0.1)
        try await waitUntil { playback.app == .music && playback.isPlaying }
    }

    @MainActor static func checkFollowsOpenAppWhenOneQuits() async throws {
        let spotify = TestSource(), music = TestSource()
        var open: Set<MusicApp> = [.spotify, .music]
        spotify.next = .success(sample())
        music.next = .success(musicSample(playing: false))
        let playback = playback(spotify: spotify, music: music, running: { open.contains($0) })
        defer { playback.stop() }
        try await waitUntil { playback.app == .spotify && playback.state == .playing }

        open.remove(.spotify)
        spotify.next = .failure(PlayerBridgeError.notRunning)
        playback.boost(for: 0.1)
        try await waitUntil { playback.app == .music && playback.state == .paused }

        open.remove(.music)
        music.next = .failure(PlayerBridgeError.notRunning)
        playback.boost(for: 0.1)
        try await waitUntil { playback.state == .notRunning }
        assert(playback.status == "Open Spotify or Apple Music" && playback.needsAttention)
    }
}
