import AppKit
import Observation
import os

enum PlaybackState: Equatable {
    /// No music app is open. Squidd never opens one unasked, so this waits for the user.
    case notRunning
    /// macOS hasn't been asked for Automation permission yet; asking shows the system prompt.
    case permissionNeeded
    /// Permission was refused. Only System Settings can undo that, so Squidd can't re-prompt.
    case permissionDenied
    case loading, idle, playing, paused, offline, commandError
}

/// Drives both panels from the music app on this Mac — Spotify or Apple Music, whichever most recently started
/// playing. The other app is ignored until it starts playing itself.
///
/// Readings arrive two ways. Each app broadcasts every state change with the track's details in its `userInfo` —
/// free, instant, and how nearly every update arrives. Apple Events fill the gaps: the artwork, which neither
/// broadcast includes, Apple Music's playback position, which its broadcast leaves out, and the state at launch,
/// before any broadcast has been sent. A slow poll runs underneath as a safety net, not as the data source.
@MainActor @Observable
final class Playback {
    private(set) var state: PlaybackState = .loading
    /// The app the card follows. Switches when another app starts playing, or when this one quits while another is
    /// open.
    private(set) var app: MusicApp
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var artworkKey = "idle"
    /// Key of the image in `artwork`. Trails `artworkKey` while a replacement loads, since the old image stays up.
    private(set) var loadedArtworkKey = "idle"
    private(set) var busy = false
    private(set) var message: String?

    private let sources: [MusicApp: any NowPlayingSource]
    /// Diagnostic trail of broadcasts and readings; `log stream --predicate 'subsystem == "com.squidd"'`.
    private let log = Logger(subsystem: "com.squidd", category: "Playback")
    private let isRunning: (MusicApp) -> Bool
    private let isPermitted: (MusicApp) -> Bool
    private let images: any ArtworkLoading
    private let pollInterval: Double
    private let idlePollInterval: Double
    private let backgroundPollInterval: Double
    private let boostInterval: Double
    private var boostUntil: Date?
    private var background = false
    private let reconciliationDelay: Double
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkRetryAt: Date?
    private var generation = UUID()
    private var revision = 0
    private var pending: (app: MusicApp, command: PlaybackCommand)?
    private var suspended = false
    private var previewing = false
    private var stopped = false
    private var retryAt: Date?
    private var failures = 0
    private var commandMessageUntil: Date?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var seekRollback: Double?
    private var observers: [NSObjectProtocol] = []
    /// The track the current `artworkKey` was fetched for, so a repeated notification for the same track doesn't
    /// spend an Apple Event re-fetching artwork that cannot have changed.
    private var artworkTrackID: String?

    /// Notifications carry the state changes, so these rates only cover what a missed notification would strand:
    /// `pollInterval` while a track plays, `idlePollInterval` while paused or idle, and `backgroundPollInterval`
    /// while only the launcher shows. `boostInterval` is the quick rate used briefly after `boost()`.
    ///
    /// `source` stands in for Spotify alone and `sources` for any set of apps, both for the checks; with neither,
    /// Squidd follows the real Spotify and Apple Music. `isRunning` and `isPermitted` let the checks decide which
    /// apps are open and allowed, rather than whatever this Mac happens to say.
    init(source: (any NowPlayingSource)? = nil, sources: [MusicApp: any NowPlayingSource]? = nil,
         isRunning: @escaping (MusicApp) -> Bool = { $0.isRunning },
         isPermitted: @escaping (MusicApp) -> Bool = { Automation.permission(for: $0) == .granted },
         images: (any ArtworkLoading)? = nil,
         pollInterval: Double = 15, idlePollInterval: Double? = nil, backgroundPollInterval: Double? = nil,
         boostInterval: Double = 2, reconciliationDelay: Double = 0.4, observeNotifications: Bool = true) {
        let sources = sources ?? source.map { [.spotify: $0] }
            ?? [.spotify: SpotifyEventBridge(), .music: AppleMusicEventBridge()]
        self.sources = sources
        self.isRunning = isRunning
        self.isPermitted = isPermitted
        let apps = MusicApp.allCases.filter { sources[$0] != nil }
        // Start on whichever app is open; the first reading switches to the other if that one is playing instead.
        app = (apps.count > 1 ? apps.first(where: isRunning) : nil) ?? apps.first ?? .spotify
        self.images = images ?? ArtworkCache()
        self.pollInterval = max(0.05, pollInterval)
        self.idlePollInterval = max(0.05, idlePollInterval ?? pollInterval * 2)
        self.backgroundPollInterval = max(0.05, backgroundPollInterval ?? self.idlePollInterval * 2)
        self.boostInterval = max(0.05, boostInterval)
        self.reconciliationDelay = max(0, reconciliationDelay)
        if observeNotifications { observePlaybackChanges() }
        start()
    }

    var duration: Double { snapshot?.duration ?? 0 }
    var title: String { snapshot?.title ?? "Nothing playing" }
    var identity: String { snapshot?.identity ?? "idle" }
    var artist: String {
        if let message { return message }
        let artist = snapshot?.artist ?? ""
        return artist.isEmpty ? status : artist
    }
    var status: String {
        switch state {
        case .notRunning: sources.count > 1 ? "Open Spotify or Apple Music" : "\(app.name) isn’t running"
        case .permissionNeeded: "Allow Squidd to control \(app.name)"
        case .permissionDenied: "Squidd isn’t allowed to control \(app.name)"
        case .loading: "Checking \(app.name)…"
        case .idle: "Open \(app.name) to start listening"
        case .playing: "Playing on \(app.name)"
        case .paused: "Paused on \(app.name)"
        case .offline: "\(app.name) isn’t responding · Retrying"
        case .commandError: "Playback command failed"
        }
    }
    /// True once the situation is one the user can act on from Settings — opening an app or granting permission.
    var needsAttention: Bool { [.notRunning, .permissionNeeded, .permissionDenied].contains(state) }
    var canRetry: Bool { !busy && !suspended && !previewing && !stopped }

    /// Whether `command` is available at all, regardless of a command already on its way. Buttons use this, so
    /// sending one doesn't dim the others for the moment the app takes to confirm it.
    func offers(_ command: PlaybackCommand) -> Bool {
        !suspended && !previewing && !stopped &&
        [.playing, .paused, .commandError].contains(state) && snapshot?.permits(command) == true
    }
    /// Whether `send` would accept `command` right now: offered, and no other command still in flight.
    func permits(_ command: PlaybackCommand) -> Bool { !busy && offers(command) }

    func send(_ requested: PlaybackCommand) {
        guard permits(requested) else { return }
        var command = requested
        if case .seek(let seconds) = command {
            guard seconds.isFinite else { return }
            let target = min(max(0, seconds), duration)
            command = .seek(target)
            seekRollback = elapsed
            elapsed = target; lastTick = ProcessInfo.processInfo.systemUptime
        }
        revision += 1 // Any already-running read predates this user action.
        pending = (app, command); busy = true
        message = nil; commandMessageUntil = nil
        sleeper?.cancel()
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        cancelWork(clear: false)
        if !value { start() }
    }
    func setPreviewing(_ value: Bool) {
        guard previewing != value else { return }
        previewing = value
        cancelWork(clear: true)
        if !value { start() }
    }
    /// Slows the safety-net poll while only the launcher is showing. Notifications keep arriving either way, so this
    /// changes very little — it exists so a stranded state still recovers, just less often.
    func setBackground(_ value: Bool) { background = value }

    func retry() {
        guard canRetry else { return }
        failures = 0; retryAt = nil
        message = nil; commandMessageUntil = nil
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    /// Reads once, soon, for moments when something is likely to have changed while Squidd wasn't listening:
    /// a music app launching, the card opening, or waking from sleep.
    func boost(for seconds: Double = 20) {
        guard enabled else { return }
        boostUntil = Date().addingTimeInterval(seconds)
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    func stop() {
        stopped = true
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
        cancelWork(clear: true)
    }

    // MARK: The apps' broadcasts

    /// Each app posts its broadcast on every play, pause and skip, with the track attached. The App Sandbox does
    /// not strip Spotify's `userInfo`, so this is the primary source of readings and costs no Apple Event.
    private func observePlaybackChanges() {
        for app in sources.keys {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: app.broadcast, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let userInfo = note.userInfo else { return }
                    self.receive(notification: userInfo, from: app)
                }
            })
        }
    }

    /// Applies one app's broadcast. Separate from the observer so checks can drive it directly.
    func receive(notification userInfo: [AnyHashable: Any], from sender: MusicApp = .spotify) {
        guard enabled, sources[sender] != nil,
              let snapshot = NowPlayingSnapshot(notification: userInfo, from: sender) else { return }
        log.debug("""
            \(sender.name, privacy: .public) broadcast: \(String(describing: snapshot.state), privacy: .public) \
            \(snapshot.trackID, privacy: .public) “\(snapshot.name, privacy: .public)” (following \(self.app.name, privacy: .public))
            """)
        if sender != app {
            // Another app starting to play takes the card over; its pauses and stops don't concern it.
            guard snapshot.isPlaying else { return }
            follow(sender)
        }
        apply(snapshot)
        // Apple Music's broadcast has no position. Read it now rather than let the clock run from a guess.
        if snapshot.positionSeconds == nil && snapshot.isLoaded { sleeper?.cancel() }
    }

    /// Moves the card to another app. What it shows is replaced by that app's next reading.
    private func follow(_ next: MusicApp) {
        guard next != app else { return }
        app = next
        revision += 1 // A read of the previous app still in flight no longer describes the card.
        failures = 0; retryAt = nil
        message = nil; commandMessageUntil = nil
    }

    // MARK: The loop

    private var enabled: Bool { !suspended && !previewing && !stopped }

    private func start() {
        guard enabled, worker == nil else { return }
        if state == .notRunning || snapshot == nil { state = .loading }
        let current = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while self.enabled && !Task.isCancelled && self.generation == current {
                if let retryAt = self.retryAt, retryAt > Date() {
                    await self.sleep(retryAt.timeIntervalSinceNow)
                    continue
                }
                self.retryAt = nil
                if let (app, command) = self.pending {
                    self.pending = nil
                    do {
                        try await self.sources[app]?.send(command)
                        guard self.valid(current) else { return }
                        self.seekRollback = nil
                        // The app reports the outgoing track for a moment after a skip, so settle before reading.
                        try await Task.sleep(for: .seconds(self.reconciliationDelay))
                        guard self.valid(current) else { return }
                        await self.refresh(current)
                    } catch {
                        guard self.valid(current) else { return }
                        if let rollback = self.seekRollback { self.elapsed = rollback; self.seekRollback = nil }
                        self.handle(error, command: true)
                    }
                    guard self.valid(current) else { return }
                    self.busy = false
                } else { await self.refresh(current) }
                guard self.valid(current) else { return }
                if self.pending != nil { continue }
                await self.sleep(self.nextPollDelay)
            }
            if self.generation == current { self.worker = nil }
        }
    }

    private func valid(_ current: UUID) -> Bool { generation == current && enabled && !Task.isCancelled }

    private var nextPollDelay: Double {
        if let boostUntil, boostUntil > Date() { return boostInterval }
        if background { return backgroundPollInterval }
        return isPlaying ? pollInterval : idlePollInterval
    }

    private func sleep(_ seconds: Double) async {
        guard !Task.isCancelled else { return }
        let current = generation
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(max(0.01, seconds))) }
        sleeper = task
        await task.value
        if generation == current { sleeper = nil }
    }

    /// One full reading over Apple Events. Costs ~80 ms off the main actor, so it runs at launch and as a safety
    /// net; the notification covers everything in between.
    private func refresh(_ current: UUID) async {
        followRunningApp()
        let startedAtRevision = revision
        let reading = app
        do {
            var value = try await sources[reading]?.snapshot()
            log.debug("""
                \(reading.name, privacy: .public) read: \(String(describing: value?.state), privacy: .public) \
                \(value?.trackID ?? "-", privacy: .public) “\(value?.name ?? "", privacy: .public)”
                """)
            guard valid(current), startedAtRevision == revision else { return }
            // Nothing playing here: another app may have started without its broadcast reaching Squidd.
            if value?.isPlaying != true, let (other, playing) = await playingElsewhere(than: reading) {
                guard valid(current), startedAtRevision == revision else { return }
                follow(other); value = playing
            }
            failures = 0
            if let value { apply(value) } else { clearNowPlaying(.idle) }
        } catch {
            log.debug("\(reading.name, privacy: .public) read failed: \(String(describing: error), privacy: .public)")
            guard valid(current), startedAtRevision == revision else { return }
            if let (other, playing) = await playingElsewhere(than: reading) {
                guard valid(current), startedAtRevision == revision else { return }
                follow(other); failures = 0
                apply(playing)
                return
            }
            handle(error, command: false)
        }
    }

    /// When the followed app has quit and another is open, follow that one instead of reporting nothing.
    private func followRunningApp() {
        guard sources.count > 1, !isRunning(app),
              let open = MusicApp.allCases.first(where: { sources[$0] != nil && isRunning($0) }) else { return }
        follow(open)
    }

    /// Checks the other apps for playback. Only apps Squidd already has permission for: reading one it doesn't
    /// would put up the Automation prompt for an app the user may not even be using. A broadcast covers those.
    private func playingElsewhere(than excluded: MusicApp) async -> (MusicApp, NowPlayingSnapshot)? {
        for other in MusicApp.allCases where other != excluded {
            guard let source = sources[other], isRunning(other), isPermitted(other),
                  let value = try? await source.snapshot(), value.isPlaying else { continue }
            return (other, value)
        }
        return nil
    }

    private func apply(_ value: NowPlayingSnapshot) {
        guard enabled else { return }
        failures = 0
        retryAt = nil
        let previous = snapshot
        var value = value
        if value.positionSeconds == nil {
            // Apple Music's broadcast: keep the clock on the same track, start from zero on a new one. The Apple
            // Event read that follows corrects either.
            value.positionSeconds = value.trackID == previous?.trackID ? elapsed : 0
        }
        snapshot = value
        elapsed = value.elapsed
        isPlaying = value.isPlaying
        state = value.isLoaded ? (isPlaying ? .playing : .paused) : .idle
        if commandMessageUntil == nil || commandMessageUntil! <= Date() {
            message = nil; commandMessageUntil = nil
        }
        if value.isAd { message = "Advertisement · Controls unavailable" }
        else if !value.isLoaded && value.isPlaying { message = "\(app.name) is playing · Metadata unavailable" }

        if let url = value.artworkURL {
            // A Spotify Apple Event reading already carries the artwork URL.
            artworkTrackID = value.trackID
            updateArtwork(.remote(url))
        } else if artworkTrackID != value.trackID {
            // Otherwise fetch it — but only when the track actually changed.
            if value.hasArtwork { fetchArtwork(for: value.trackID) }
            else { artworkTrackID = value.trackID; updateArtwork(nil) }
        }
        reconcileClock()
    }

    /// The single Apple Event a running Squidd makes in normal use: one per track change, ~8 ms, off the main actor.
    private func fetchArtwork(for trackID: String) {
        let current = generation
        let reading = app
        Task { [weak self] in
            guard let self else { return }
            // A failed lookup leaves `artworkTrackID` alone, so the next reading tries again. Only an answer — an
            // image, or "this track has none" — settles it for the track.
            let artwork: ArtworkReference?
            do { artwork = try await self.sources[reading]?.artwork(for: trackID) } catch {
                self.log.debug("\(reading.name, privacy: .public) artwork failed: \(String(describing: error), privacy: .public)")
                return
            }
            self.log.debug("\(reading.name, privacy: .public) artwork: \(artwork?.key ?? "none", privacy: .public)")
            guard self.generation == current, self.enabled, self.app == reading,
                  self.snapshot?.trackID == trackID else { return }
            self.artworkTrackID = trackID
            if case .remote(let url) = artwork { self.snapshot?.artworkURL = url }
            self.updateArtwork(artwork)
        }
    }

    private func noteAppClosed() {
        clearNowPlaying(.notRunning)
        message = nil
        // Nothing to poll for until an app comes back; WindowCoordinator boosts on launch.
        retryAt = Date().addingTimeInterval(max(2, idlePollInterval))
    }

    private func clearNowPlaying(_ next: PlaybackState) {
        snapshot = nil
        elapsed = 0
        isPlaying = false
        clock?.cancel(); clock = nil
        artworkTrackID = nil
        updateArtwork(nil)
        state = next
    }

    private func handle(_ error: Error, command: Bool) {
        isPlaying = false; clock?.cancel(); clock = nil
        failures = min(8, failures + 1)
        let backoff = min(60, pow(2, Double(failures)))
        switch error {
        case PlayerBridgeError.permissionDenied:
            // Waiting doesn't fix a refusal; Settings offers the way to System Settings.
            clearNowPlaying(Automation.permission(for: app) == .notAsked ? .permissionNeeded : .permissionDenied)
            message = PlayerBridgeError.permissionDenied.description(for: app)
            retryAt = Date().addingTimeInterval(30)
            return
        case PlayerBridgeError.notRunning:
            noteAppClosed()
            return
        case PlayerBridgeError.nothingPlaying:
            clearNowPlaying(.idle)
            return
        default:
            state = command ? .commandError : .offline
            retryAt = Date().addingTimeInterval(backoff)
        }
        if command { commandMessageUntil = Date().addingTimeInterval(6) }
        if let known = error as? PlayerBridgeError { message = known.description(for: app) }
        else { message = command ? "Command failed. Try again." : "Lost contact with \(app.name) · Retrying" }
    }

    private func reconcileClock() {
        clock?.cancel(); clock = nil
        guard isPlaying, enabled else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.elapsed = min(self.duration, self.elapsed + now - self.lastTick)
                self.lastTick = now
            }
        }
    }

    private func updateArtwork(_ artwork: ArtworkReference?) {
        let key = artwork?.key ?? "idle"
        let changed = key != artworkKey
        guard changed || (loadedArtworkKey != key && artworkTask == nil && (artworkRetryAt == nil || artworkRetryAt! <= Date())) else { return }
        artworkTask?.cancel(); artworkTask = nil
        if changed { artworkRetryAt = nil }
        artworkKey = key
        guard let artwork else { self.artwork = nil; loadedArtworkKey = "idle"; return }
        guard enabled else { return }
        // Keep the displayed image until its replacement is decoded.
        let current = generation
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled && self.generation == current && self.artworkKey == key { self.artworkTask = nil }
            }
            do {
                let cgImage = try await self.images.image(for: artwork)
                guard !Task.isCancelled, self.generation == current, self.artworkKey == key else { return }
                self.artwork = NSImage(cgImage: cgImage, size: .zero)
                self.loadedArtworkKey = key
            } catch {
                if !Task.isCancelled && self.generation == current && self.artworkKey == key {
                    self.artwork = nil
                    self.loadedArtworkKey = "idle"
                    self.artworkRetryAt = Date().addingTimeInterval(30)
                }
            }
        }
    }

    private func cancelWork(clear: Bool) {
        generation = UUID(); revision += 1
        worker?.cancel(); worker = nil
        sleeper?.cancel(); sleeper = nil
        clock?.cancel(); clock = nil
        artworkTask?.cancel(); artworkTask = nil
        pending = nil; busy = false; seekRollback = nil; isPlaying = false
        retryAt = nil; failures = 0
        if clear {
            snapshot = nil; elapsed = 0; artwork = nil; artworkKey = "idle"; loadedArtworkKey = "idle"
            artworkRetryAt = nil; artworkTrackID = nil
            message = nil; commandMessageUntil = nil; state = .loading
        } else if artwork == nil { artworkKey = "idle" }
    }
}
