import AppKit
import Observation

enum SpotifyPlaybackState: Equatable {
    /// Spotify isn't open. Squidd never opens it unasked, so this waits for the user.
    case notRunning
    /// macOS hasn't been asked for Automation permission yet; asking shows the system prompt.
    case permissionNeeded
    /// Permission was refused. Only System Settings can undo that, so Squidd can't re-prompt.
    case permissionDenied
    case loading, idle, playing, paused, offline, commandError
}

/// Drives both panels from the Spotify app on this Mac.
///
/// Readings arrive two ways. Spotify broadcasts `PlaybackStateChanged` on every state change with the whole snapshot
/// in its `userInfo` — free, instant, and how nearly every update arrives. Apple Events fill the two gaps: the
/// artwork URL, which the notification omits, and the state at launch, before any notification has been sent. A slow
/// poll runs underneath as a safety net, not as the data source.
@MainActor @Observable
final class SpotifyPlayback {
    private(set) var state: SpotifyPlaybackState = .loading
    private(set) var snapshot: SpotifyPlaybackSnapshot?
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var artworkKey = "idle"
    /// Key of the image in `artwork`. Trails `artworkKey` while a replacement loads, since the old image stays up.
    private(set) var loadedArtworkKey = "idle"
    private(set) var busy = false
    private(set) var message: String?

    private let source: any NowPlayingSource
    private let images: any SpotifyArtworkLoading
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
    private var pending: PlaybackCommand?
    private var suspended = false
    private var previewing = false
    private var stopped = false
    private var retryAt: Date?
    private var failures = 0
    private var commandMessageUntil: Date?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var seekRollback: Double?
    private var observer: NSObjectProtocol?
    /// The track the current `artworkKey` was fetched for, so a repeated notification for the same track doesn't
    /// spend an Apple Event re-fetching a URL that cannot have changed.
    private var artworkTrackID: String?

    /// Notifications carry the state changes, so these rates only cover what a missed notification would strand:
    /// `pollInterval` while a track plays, `idlePollInterval` while paused or idle, and `backgroundPollInterval`
    /// while only the launcher shows. `boostInterval` is the quick rate used briefly after `boost()`.
    init(source: (any NowPlayingSource)? = nil, images: (any SpotifyArtworkLoading)? = nil,
         pollInterval: Double = 15, idlePollInterval: Double? = nil, backgroundPollInterval: Double? = nil,
         boostInterval: Double = 2, reconciliationDelay: Double = 0.4, observeNotifications: Bool = true) {
        self.source = source ?? SpotifyEventBridge()
        self.images = images ?? SpotifyArtworkCache()
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
        case .notRunning: "Spotify isn’t running"
        case .permissionNeeded: "Allow Squidd to control Spotify"
        case .permissionDenied: "Squidd isn’t allowed to control Spotify"
        case .loading: "Checking Spotify…"
        case .idle: "Open Spotify to start listening"
        case .playing: "Playing on Spotify"
        case .paused: "Paused on Spotify"
        case .offline: "Spotify isn’t responding · Retrying"
        case .commandError: "Playback command failed"
        }
    }
    /// True once the situation is one the user can act on from Settings — opening Spotify or granting permission.
    var needsAttention: Bool { [.notRunning, .permissionNeeded, .permissionDenied].contains(state) }
    var canRetry: Bool { !busy && !suspended && !previewing && !stopped }

    /// Whether `command` is available at all, regardless of a command already on its way. Buttons use this, so
    /// sending one doesn't dim the others for the moment Spotify takes to confirm it.
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
        pending = command; busy = true
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
    /// Spotify launching, the card opening, or waking from sleep.
    func boost(for seconds: Double = 20) {
        guard enabled else { return }
        boostUntil = Date().addingTimeInterval(seconds)
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    func stop() {
        stopped = true
        if let observer { DistributedNotificationCenter.default().removeObserver(observer); self.observer = nil }
        cancelWork(clear: true)
    }

    // MARK: Spotify's broadcast

    /// Spotify posts this on every play, pause, skip and seek, with the whole snapshot attached. The App Sandbox
    /// does not strip the `userInfo`, so this is the primary source of readings and costs no Apple Event.
    private func observePlaybackChanges() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let userInfo = note.userInfo else { return }
                self.receive(notification: userInfo)
            }
        }
    }

    /// Applies one of Spotify's broadcasts. Separate from the observer so checks can drive it directly.
    func receive(notification userInfo: [AnyHashable: Any]) {
        guard let snapshot = SpotifyPlaybackSnapshot(notification: userInfo) else { return }
        apply(snapshot, from: .notification)
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
                if let command = self.pending {
                    self.pending = nil
                    do {
                        try await self.source.send(command)
                        guard self.valid(current) else { return }
                        self.seekRollback = nil
                        // Spotify reports the outgoing track for a moment after a skip, so settle before reading.
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
        let startedAtRevision = revision
        do {
            let value = try await source.snapshot()
            guard valid(current), startedAtRevision == revision else { return }
            failures = 0
            if let value { apply(value, from: .appleEvent) } else { clearNowPlaying(.idle) }
        } catch {
            guard valid(current) else { return }
            if startedAtRevision != revision { return }
            handle(error, command: false)
        }
    }

    private enum Reading { case notification, appleEvent }

    private func apply(_ value: SpotifyPlaybackSnapshot, from reading: Reading) {
        guard enabled else { return }
        failures = 0
        retryAt = nil
        let previous = snapshot
        snapshot = value
        elapsed = value.elapsed
        isPlaying = value.isPlaying
        state = value.isLoaded ? (isPlaying ? .playing : .paused) : .idle
        if commandMessageUntil == nil || commandMessageUntil! <= Date() {
            message = nil; commandMessageUntil = nil
        }
        if value.isAd { message = "Advertisement · Controls unavailable" }
        else if !value.isLoaded && value.isPlaying { message = "Spotify is playing · Metadata unavailable" }

        switch reading {
        case .appleEvent:
            // An Apple Event snapshot already carries the artwork URL.
            artworkTrackID = value.trackID
            updateArtwork(value.artworkURL)
        case .notification:
            // The notification omits the URL, so fetch one — but only when the track actually changed.
            if value.trackID != previous?.trackID || artworkTrackID != value.trackID {
                if value.hasArtwork { fetchArtworkURL(for: value.trackID) }
                else { artworkTrackID = value.trackID; updateArtwork(nil) }
            }
        }
        reconcileClock()
    }

    /// The single Apple Event a running Squidd makes in normal use: one per track change, ~8 ms, off the main actor.
    private func fetchArtworkURL(for trackID: String) {
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            let url = try? await self.source.artworkURL()
            guard self.generation == current, self.enabled, self.snapshot?.trackID == trackID else { return }
            self.artworkTrackID = trackID
            self.snapshot?.artworkURL = url
            self.updateArtwork(url)
        }
    }

    private func noteSpotifyClosed() {
        clearNowPlaying(.notRunning)
        message = nil
        // Nothing to poll for until Spotify comes back; WindowCoordinator boosts on launch.
        retryAt = Date().addingTimeInterval(max(2, idlePollInterval))
    }

    private func clearNowPlaying(_ next: SpotifyPlaybackState) {
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
        case SpotifyBridgeError.permissionDenied:
            // Waiting doesn't fix a refusal; Settings offers the way to System Settings.
            clearNowPlaying(SpotifyAutomation.permission() == .notAsked ? .permissionNeeded : .permissionDenied)
            message = SpotifyBridgeError.permissionDenied.localizedDescription
            retryAt = Date().addingTimeInterval(30)
            return
        case SpotifyBridgeError.notRunning:
            noteSpotifyClosed()
            return
        case SpotifyBridgeError.nothingPlaying:
            clearNowPlaying(.idle)
            return
        default:
            state = command ? .commandError : .offline
            retryAt = Date().addingTimeInterval(backoff)
        }
        if command { commandMessageUntil = Date().addingTimeInterval(6) }
        if let known = error as? SpotifyBridgeError { message = known.localizedDescription }
        else { message = command ? "Command failed. Try again." : "Lost contact with Spotify · Retrying" }
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

    private func updateArtwork(_ url: URL?) {
        let key = url?.absoluteString ?? "idle"
        let changed = key != artworkKey
        guard changed || (loadedArtworkKey != key && artworkTask == nil && (artworkRetryAt == nil || artworkRetryAt! <= Date())) else { return }
        artworkTask?.cancel(); artworkTask = nil
        if changed { artworkRetryAt = nil }
        artworkKey = key
        guard let url else { artwork = nil; loadedArtworkKey = "idle"; return }
        guard enabled else { return }
        // Keep the displayed image until its replacement is decoded.
        let current = generation
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled && self.generation == current && self.artworkKey == key { self.artworkTask = nil }
            }
            do {
                let cgImage = try await self.images.image(for: url)
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
