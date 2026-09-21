import Foundation

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
            return snapshot
        }
        return snapshot
    }

    func artwork(for trackID: String) async throws -> ArtworkReference? {
        try ready()
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
