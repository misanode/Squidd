import Foundation

/// Talks to the Music app over Apple Events. Its player vocabulary matches Spotify's code for code; the differences
/// are the track identifier, duration in seconds, transport event codes, and artwork arriving as image bytes.
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

    /// The first answered event means the Automation prompt, if there was one, is behind us: back to short timeouts.
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
            // `persistent ID` is 16 hex digits; normalized so it matches the number in the broadcast.
            let hex = try client.trackText("pPIS")
            snapshot.trackID = NowPlayingSnapshot.musicTrackID(hex: hex) ?? "music:\(hex)"
            snapshot.name = try client.trackText("pnam")
            snapshot.artist = (try? client.trackText("pArt")) ?? ""
            snapshot.album = (try? client.trackText("pAlb")) ?? ""
            // Seconds here, unlike the broadcast's milliseconds. A radio stream has no duration at all.
            snapshot.durationMilliseconds = ((try? client.trackNumber("pDur")) ?? 0) * 1000
            snapshot.hasArtwork = true
        } catch PlayerBridgeError.nothingPlaying {
            return snapshot
        }
        return snapshot
    }

    /// `raw data of artwork 1 of current track` — the image as stored, usually JPEG or PNG. Read once per track,
    /// since it can run to a few hundred kilobytes.
    func artwork(for trackID: String) async throws -> ArtworkReference? {
        try ready()
        let artwork = AppleEvents.element(AppleEvents.code("cArt"), index: 1, of: client.currentTrack)
        // "No such object" means the track has no artwork; anything else is a failure worth retrying.
        do {
            let value = try client.get(AppleEvents.property(AppleEvents.code("pRaw"), of: artwork))
            return value.data.isEmpty ? nil : .embedded(key: "\(trackID)#artwork", data: value.data)
        } catch PlayerBridgeError.nothingPlaying {
            return nil
        }
    }

    func send(_ command: PlaybackCommand) async throws {
        try ready()
        switch command {
        case .play: try client.perform(client.event("hook", "Play"))
        case .pause: try client.perform(client.event("hook", "Paus"))
        case .next: try client.perform(client.event("hook", "Next"))
        // `back track`, which is what Music's own ⏮ button does: restart the song, or go back if already near
        // the start. `previous track` would always skip back, which feels wrong a minute into a song.
        case .previous: try client.perform(client.event("hook", "Back"))
        case .seek(let seconds): try client.setPosition(seconds)
        }
    }
}
