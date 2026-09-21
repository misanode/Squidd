import Foundation

/// Talks to the Spotify app over Apple Events. An actor, so the sends serialize and stay off the main thread.
actor SpotifyEventBridge: NowPlayingSource {
    private var client: AppleEventClient
    private let timeout: TimeInterval
    private var answered = false

    init(timeout: TimeInterval = 2) {
        self.timeout = max(0.1, timeout)
        client = AppleEventClient(app: .spotify, timeout: AppleEventClient.firstContactTimeout)
    }

    private func ready() throws {
        guard MusicApp.spotify.isRunning else { throw PlayerBridgeError.notRunning }
    }

    /// The first answered event means the Automation prompt, if there was one, is behind us: back to short timeouts.
    private func noteAnswered() {
        guard !answered else { return }
        answered = true
        client = client.with(timeout: timeout)
    }

    func snapshot() async throws -> NowPlayingSnapshot? {
        try ready()
        var snapshot = NowPlayingSnapshot()
        snapshot.state = try client.playerState()
        noteAnswered()
        // Stopped means nothing is loaded; the remaining reads would only fail.
        guard snapshot.state != .stopped else { return snapshot }
        snapshot.positionSeconds = (try? client.number(of: "pPos")) ?? 0
        do {
            snapshot.trackID = try client.trackText("ID  ")
            snapshot.name = try client.trackText("pnam")
            snapshot.artist = try client.trackText("pArt")
            snapshot.album = try client.trackText("pAlb")
            snapshot.durationMilliseconds = try client.trackNumber("pDur")
            let artwork = (try? client.trackText("aUrl")) ?? ""
            snapshot.artworkURL = URL(string: artwork)
            snapshot.hasArtwork = snapshot.artworkURL != nil
        } catch PlayerBridgeError.nothingPlaying {
            // Spotify says it is playing but exposes no track: an ad or a gap between tracks.
            return snapshot
        }
        return snapshot
    }

    /// Fetches only the artwork URL. This is the one field the notification omits, so it is the one Apple Event a
    /// running Squidd makes in normal use — once per track change.
    func artwork(for trackID: String) async throws -> ArtworkReference? {
        try ready()
        // "No such object" means the track has no artwork; anything else is a failure worth retrying.
        do {
            return URL(string: try client.trackText("aUrl")).map(ArtworkReference.remote)
        } catch PlayerBridgeError.nothingPlaying {
            return nil
        }
    }

    func send(_ command: PlaybackCommand) async throws {
        try ready()
        switch command {
        case .play: try client.perform(client.event("spfy", "Play"))
        case .pause: try client.perform(client.event("spfy", "Paus"))
        case .next: try client.perform(client.event("spfy", "Next"))
        case .previous: try client.perform(client.event("spfy", "Prev"))
        case .seek(let seconds): try client.setPosition(seconds)
        }
    }
}
