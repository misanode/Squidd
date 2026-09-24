import Foundation

actor AppleMusicEventBridge: NowPlayingSource {
    private var client: AppleEventClient
    private let timeout: TimeInterval
    private var answered = false

    init(timeout: TimeInterval = 2) {
        self.timeout = max(0.1, timeout)
        client = AppleEventClient(app: .music, timeout: AppleEventClient.firstContactTimeout)
    }

    private func ready() throws {
        guard MusicApp.music.isRunning else { throw PlayerBridgeError.notRunning }
    }

    private func noteAnswered() {
        guard !answered else { return }
        answered = true
        client = client.with(timeout: timeout)
    }

    func snapshot() async throws -> NowPlayingSnapshot? {
        try ready()
        var snapshot = NowPlayingSnapshot()
        snapshot.app = .music
        snapshot.state = try client.playerState()
        noteAnswered()
        guard snapshot.state != .stopped else { return snapshot }
        snapshot.positionSeconds = (try? client.number(of: "pPos")) ?? 0
        do {
            let hex = try client.trackText("pPIS")
            snapshot.trackID = NowPlayingSnapshot.musicTrackID(hex: hex) ?? "music:\(hex)"
            snapshot.name = try client.trackText("pnam")
            snapshot.artist = (try? client.trackText("pArt")) ?? ""
            snapshot.album = (try? client.trackText("pAlb")) ?? ""
            snapshot.durationMilliseconds = ((try? client.trackNumber("pDur")) ?? 0) * 1000
            snapshot.hasArtwork = true
        } catch PlayerBridgeError.nothingPlaying {
            return snapshot
        }
        return snapshot
    }

    func artwork(for trackID: String) async throws -> ArtworkReference? {
        try ready()
        let artworkElement = AppleEvents.element(AppleEvents.code("cArt"), index: 1, of: client.currentTrack)
        do {
            let value = try client.get(AppleEvents.property(AppleEvents.code("pRaw"), of: artworkElement))
            if !value.data.isEmpty { return .embedded(key: "\(trackID)#artwork", data: value.data) }
        } catch PlayerBridgeError.nothingPlaying {}
        let name: String
        do { name = try client.trackText("pnam") } catch PlayerBridgeError.nothingPlaying { return nil }
        guard !name.isEmpty else { return nil }
        let artist = (try? client.trackText("pArt")) ?? ""
        let album = (try? client.trackText("pAlb")) ?? ""
        guard let url = try await ITunesArtworkLookup.shared.url(name: name, artist: artist, album: album) else { return nil }
        return .remote(url)
    }

    func send(_ command: PlaybackCommand) async throws {
        try ready()
        switch command {
        case .play: try client.perform(client.event("hook", "Play"))
        case .pause: try client.perform(client.event("hook", "Paus"))
        case .next: try client.perform(client.event("hook", "Next"))
        case .previous: try client.perform(client.event("hook", "Back"))
        case .seek(let seconds): try client.setPosition(seconds)
        }
    }
}
