import AppKit
import Foundation

actor EmptyArtwork: SpotifyArtworkLoading {
    func image(for url: URL) async throws -> CGImage { throw URLError(.cannotDecodeContentData) }
}

@MainActor
final class HeldArtwork: SpotifyArtworkLoading {
    var pending: [URL: CheckedContinuation<CGImage, Error>] = [:]
    var requested: [URL] = []
    func image(for url: URL) async throws -> CGImage {
        requested.append(url)
        return try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
    func complete(_ url: URL, image: CGImage) { pending.removeValue(forKey: url)?.resume(returning: image) }
}

/// Stands in for the Spotify app. Nothing here sends an Apple Event.
@MainActor
final class TestSource: NowPlayingSource {
    var next: Result<SpotifyPlaybackSnapshot?, Error> = .success(nil)
    var artwork: Result<URL?, Error> = .success(nil)
    var held: CheckedContinuation<SpotifyPlaybackSnapshot?, Error>?
    var holdNext = false
    var commandFailure: Error?
    var sent: [PlaybackCommand] = []
    var reads = 0
    var artworkReads = 0
    var active = 0
    var maximumActive = 0

    func snapshot() async throws -> SpotifyPlaybackSnapshot? {
        reads += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdNext { holdNext = false; return try await withCheckedThrowingContinuation { held = $0 } }
        return try next.get()
    }
    func artworkURL() async throws -> URL? {
        artworkReads += 1
        return try artwork.get()
    }
    func send(_ command: PlaybackCommand) async throws {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        sent.append(command)
        if let commandFailure { throw commandFailure }
    }
    func release(_ result: Result<SpotifyPlaybackSnapshot?, Error>) { let p = held; held = nil; p?.resume(with: result) }
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
                       durationMilliseconds: Double = 200_000, artwork: String? = nil) -> SpotifyPlaybackSnapshot {
        var snapshot = SpotifyPlaybackSnapshot()
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

    /// Shaped like a real `PlaybackStateChanged` payload, captured from Spotify.
    static func broadcast(state: String = "Playing", id: String = "spotify:track:one", name: String = "Juno",
                          position: Double = 126.39, duration: Int = 223_192,
                          artwork: Int = 1) -> [AnyHashable: Any] {
        ["Player State": state, "Track ID": id, "Name": name, "Artist": "Sabrina Carpenter",
         "Album": "Short n' Sweet", "Album Artist": "Sabrina Carpenter", "Duration": duration,
         "Playback Position": position, "Has Artwork": artwork, "Track Number": 10, "Disc Number": 1,
         "Popularity": 83, "Play Count": 0]
    }

    @MainActor
    static func playback(_ source: TestSource, images: (any SpotifyArtworkLoading)? = nil,
                         pollInterval: Double = 0.05, idlePollInterval: Double? = nil,
                         backgroundPollInterval: Double? = nil, boostInterval: Double = 0.02,
                         reconciliationDelay: Double = 0) -> SpotifyPlayback {
        // Notification observation off: the checks drive `receive(notification:)` instead of a real broadcast.
        SpotifyPlayback(source: source, images: images ?? EmptyArtwork(), pollInterval: pollInterval,
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
        print("Spotify playback checks passed")
        if CommandLine.arguments.contains("--integration") { try await checkAgainstRealSpotify() }
    }

    // MARK: Integration (opt-in)

    /// Talks to the Spotify actually running on this Mac. Opt-in with `--integration`, because it needs Spotify
    /// open with a track loaded, and because Apple Events sent from a terminal are attributed to that terminal —
    /// so the Automation prompt, if it appears, names the terminal rather than Squidd.
    ///
    /// It pauses and resumes once, which is briefly audible, and seeks to the position the track is already at,
    /// which is not. Both write paths use different event codes, so both are worth exercising.
    @MainActor static func checkAgainstRealSpotify() async throws {
        guard SpotifyEventBridge.isSpotifyRunning else {
            print("Integration checks skipped: Spotify isn't running")
            return
        }
        let permission = SpotifyAutomation.permission()
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
        // The units, against the live app: a track is minutes long, not hours, and position sits inside it.
        assert(snapshot.duration > 1 && snapshot.duration < 24 * 3600,
               "Duration looks wrong in seconds: \(snapshot.duration) — is Spotify still reporting milliseconds?")
        assert(snapshot.positionSeconds <= snapshot.duration + 1, "Position should fall within the track")

        let artwork = try await bridge.artworkURL()
        if snapshot.hasArtwork {
            assert(artwork?.scheme == "https", "Artwork should be an https URL, got \(String(describing: artwork))")
        }

        // Transport, restoring whatever state the track was in.
        let wasPlaying = snapshot.isPlaying
        try await bridge.send(wasPlaying ? .pause : .play)
        try await Task.sleep(for: .milliseconds(400))
        let flipped = try await bridge.snapshot()
        assert(flipped?.isPlaying == !wasPlaying, "Play/pause should change the reported state")
        try await bridge.send(wasPlaying ? .play : .pause)
        try await Task.sleep(for: .milliseconds(400))

        // Seek to where it already is: proves the write path without moving the track.
        if let now = try await bridge.snapshot()?.elapsed, now > 0 {
            try await bridge.send(.seek(now))
        }
        print("Integration checks passed against the running Spotify: '\(snapshot.name)' by \(snapshot.artist)")
    }

    // MARK: Snapshot

    @MainActor static func checkSnapshotValues() throws {
        // Spotify reports duration in milliseconds and position in seconds. Getting this backwards is the single
        // easiest mistake here, so it is pinned down.
        let track = sample()
        assert(track.duration == 200, "duration should convert milliseconds to seconds")
        assert(track.elapsed == 10)
        assert(track.identity == "spotify:track:one")
        assert(track.title == "Track")
        assert(track.isLoaded && track.isPlaying && !track.isAd && !track.isLocal)
        assert(track.permits(.play) && track.permits(.next) && track.permits(.seek(10)))

        // Past the end clamps rather than running away.
        let overrun = sample(position: 500)
        assert(overrun.elapsed == 200)

        // An ad: named plainly, and no transport.
        var ad = sample(id: "spotify:ad:abc")
        ad.name = ""
        assert(ad.isAd && ad.title == "Advertisement")
        assert(!ad.permits(.play) && !ad.permits(.next) && !ad.permits(.seek(1)))

        // A local file has no artwork URL but still plays and seeks.
        let local = sample(id: "spotify:local:something")
        assert(local.isLocal && local.artworkURL == nil && local.permits(.seek(1)))

        // Stopped: nothing loaded, nothing offered.
        var stopped = SpotifyPlaybackSnapshot()
        stopped.state = .stopped
        assert(!stopped.isLoaded && stopped.title == "Nothing playing" && stopped.identity == "idle")
        assert(!stopped.permits(.play))

        // Playing with no metadata at all — Spotify does this in the gap between tracks.
        var blank = SpotifyPlaybackSnapshot()
        blank.state = .playing
        assert(blank.title == "Playback unavailable")

        // A zero duration hides the scrubber rather than offering a seek into nothing.
        let unknownLength = sample(durationMilliseconds: 0)
        assert(unknownLength.duration == 0 && !unknownLength.permits(.seek(1)) && unknownLength.permits(.play))
    }

    // MARK: Notification

    @MainActor static func checkNotificationParsing() throws {
        guard let parsed = SpotifyPlaybackSnapshot(notification: broadcast()) else {
            fatalError("A well-formed broadcast should parse")
        }
        assert(parsed.isPlaying && parsed.trackID == "spotify:track:one")
        assert(parsed.name == "Juno" && parsed.artist == "Sabrina Carpenter" && parsed.album == "Short n' Sweet")
        assert(abs(parsed.duration - 223.192) < 0.001, "Duration arrives in milliseconds here too")
        assert(abs(parsed.elapsed - 126.39) < 0.001, "Playback Position arrives in seconds")
        assert(parsed.hasArtwork)

        let paused = SpotifyPlaybackSnapshot(notification: broadcast(state: "Paused"))
        assert(paused?.isPlaying == false && paused?.isLoaded == true)

        // "Stopped" means nothing is loaded, whatever else the payload says.
        let stopped = SpotifyPlaybackSnapshot(notification: broadcast(state: "Stopped"))
        assert(stopped?.isLoaded == false)

        // Without a player state there is nothing to trust.
        assert(SpotifyPlaybackSnapshot(notification: ["Name": "Juno"]) == nil)

        // Missing optional keys degrade rather than crash.
        let sparse = SpotifyPlaybackSnapshot(notification: ["Player State": "Playing"])
        assert(sparse?.name == "" && sparse?.duration == 0 && sparse?.isLoaded == false)

        // Has Artwork = 0 means don't spend an Apple Event looking for a URL.
        let artless = SpotifyPlaybackSnapshot(notification: broadcast(artwork: 0))
        assert(artless?.hasArtwork == false)

        // Titles are arbitrary text; nothing here is delimiter-parsed, so punctuation is just punctuation.
        let awkward = SpotifyPlaybackSnapshot(notification: broadcast(name: "a|b\u{1}c — “quoted” 🎧"))
        assert(awkward?.name == "a|b\u{1}c — “quoted” 🎧")

        let ad = SpotifyPlaybackSnapshot(notification: broadcast(id: "spotify:ad:xyz", name: "Some Ad"))
        assert(ad?.isAd == true && ad?.title == "Advertisement" && ad?.permits(.next) == false)
    }

    // MARK: Errors

    @MainActor static func checkErrorMapping() throws {
        assert(SpotifyBridgeError(status: -1743) == .permissionDenied)
        assert(SpotifyBridgeError(status: -600) == .notRunning)
        assert(SpotifyBridgeError(status: -609) == .notRunning)
        assert(SpotifyBridgeError(status: -1712) == .timedOut)
        assert(SpotifyBridgeError(status: -1728) == .nothingPlaying)
        assert(SpotifyBridgeError(status: -1701) == .failed(-1701))
        assert(SpotifyBridgeError.notRunning.localizedDescription.contains("Spotify"))
    }

    // MARK: Controller

    @MainActor static func checkInitialReadAndCommands() async throws {
        let source = TestSource()
        source.next = .success(sample())
        let playback = playback(source)
        defer { playback.stop() }

        // Nothing has broadcast yet, so the opening state comes from one Apple Event read.
        try await waitUntil { playback.state == .playing }
        assert(playback.title == "Track" && playback.duration == 200)
        assert(source.reads >= 1)

        // Commands serialize: one in flight at a time, duplicates while busy ignored.
        source.next = .success(sample(playing: false))
        playback.send(.pause)
        playback.send(.pause)
        playback.send(.next)
        try await waitUntil { !playback.busy }
        assert(source.sent == [.pause], "A second command while one is in flight should be dropped")
        assert(source.maximumActive == 1, "Reads and commands must not overlap")
        try await waitUntil { playback.state == .paused }

        // A read that started before a command must not overwrite what the command produced.
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

        // A broadcast alone should move the whole widget, with no Apple Event read.
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

        // A payload with no player state is ignored rather than clearing the card.
        playback.receive(notification: broadcast())
        let before = playback.identity
        playback.receive(notification: ["Name": "nonsense"])
        assert(playback.identity == before)
    }

    @MainActor static func checkArtworkFetchedOncePerTrack() async throws {
        let source = TestSource()
        let images = HeldArtwork()
        source.next = .success(nil)
        source.artwork = .success(URL(string: "https://i.scdn.co/image/one")!)
        let playback = playback(source, images: images, pollInterval: 30, idlePollInterval: 30)
        defer { playback.stop() }
        try await waitUntil { playback.state == .idle }

        // First broadcast for a track: one artwork lookup, the one Apple Event normal use makes.
        playback.receive(notification: broadcast())
        try await waitUntil { source.artworkReads == 1 }
        try await waitUntil { playback.artworkKey == "https://i.scdn.co/image/one" }

        // Repeat broadcasts for the same track (pause, resume, seek) must not look it up again.
        playback.receive(notification: broadcast(state: "Paused"))
        playback.receive(notification: broadcast(position: 130))
        try await Task.sleep(for: .milliseconds(80))
        assert(source.artworkReads == 1, "Artwork should be fetched once per track, not per broadcast")

        // A new track fetches again.
        source.artwork = .success(URL(string: "https://i.scdn.co/image/two")!)
        playback.receive(notification: broadcast(id: "spotify:track:two", name: "Espresso"))
        try await waitUntil { source.artworkReads == 2 }
        try await waitUntil { playback.artworkKey == "https://i.scdn.co/image/two" }

        // Has Artwork = 0 clears the slot without a lookup.
        playback.receive(notification: broadcast(id: "spotify:track:three", artwork: 0))
        try await waitUntil { playback.artworkKey == "idle" }
        assert(source.artworkReads == 2, "No artwork means no lookup")

        // The displayed image trails the key until the replacement decodes.
        assert(playback.loadedArtworkKey == "idle")
    }

    @MainActor static func checkSeekRollback() async throws {
        let source = TestSource()
        source.next = .success(sample(position: 10))
        let playback = playback(source, pollInterval: 30, idlePollInterval: 30)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }

        // A seek previews locally straight away, so the scrubber follows the thumb.
        source.commandFailure = SpotifyBridgeError.timedOut
        playback.send(.seek(120))
        assert(abs(playback.elapsed - 120) < 0.001)
        // When the command fails the preview rolls back rather than lying.
        try await waitUntil { !playback.busy }
        assert(abs(playback.elapsed - 10) < 1, "A failed seek should roll back")
        assert(playback.state == .commandError)

        // A seek past the end is clamped to the track length before being sent.
        source.commandFailure = nil
        playback.retry()
        try await waitUntil { playback.state == .playing }
        playback.send(.seek(9999))
        try await waitUntil { !playback.busy }
        assert(source.sent.contains(.seek(200)), "Seek should clamp to the duration")
    }

    @MainActor static func checkFailureStates() async throws {
        // Spotify closed.
        let closed = TestSource()
        closed.next = .failure(SpotifyBridgeError.notRunning)
        let first = playback(closed)
        try await waitUntil { first.state == .notRunning }
        assert(first.needsAttention && first.snapshot == nil && first.artworkKey == "idle")
        assert(!first.offers(.play))
        first.stop()

        // Permission refused: a state the user has to resolve, so it does not retry in a tight loop.
        let denied = TestSource()
        denied.next = .failure(SpotifyBridgeError.permissionDenied)
        let second = playback(denied)
        try await waitUntil { second.state == .permissionDenied || second.state == .permissionNeeded }
        assert(second.needsAttention)
        assert(second.message?.isEmpty == false)
        let reads = denied.reads
        try await Task.sleep(for: .milliseconds(150))
        assert(denied.reads == reads, "A refusal should not be retried on the poll interval")
        second.stop()

        // Nothing loaded in a running Spotify.
        let empty = TestSource()
        empty.next = .failure(SpotifyBridgeError.nothingPlaying)
        let third = playback(empty)
        try await waitUntil { third.state == .idle }
        assert(!third.needsAttention)
        third.stop()

        // A transient failure backs off but keeps trying, and recovers on its own.
        let flaky = TestSource()
        flaky.next = .failure(SpotifyBridgeError.timedOut)
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

        // Preview owns the card: live reading stops and the live snapshot is dropped.
        playback.setPreviewing(true)
        try await Task.sleep(for: .milliseconds(60))
        let duringPreview = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == duringPreview, "Preview must generate no Spotify traffic")
        assert(playback.snapshot == nil && !playback.offers(.play))
        // A broadcast arriving during preview is ignored rather than fighting the sample data.
        playback.receive(notification: broadcast())
        assert(playback.snapshot == nil)

        playback.setPreviewing(false)
        try await waitUntil { playback.state == .playing }

        // Sleep and lock suspend the same way.
        playback.setSuspended(true)
        try await Task.sleep(for: .milliseconds(60))
        let duringSleep = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == duringSleep, "Nothing should be read while nobody can see the widget")
        playback.setSuspended(false)
        try await waitUntil { playback.state == .playing }

        // Stopping is final.
        playback.stop()
        let afterStop = source.reads
        try await Task.sleep(for: .milliseconds(120))
        assert(source.reads == afterStop)
    }
}
