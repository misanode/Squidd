# Native rebuild progress

## Approved visual baseline

User approved the native layout on 2026-09-10. Preserve the clear Liquid Glass,
0.5-point white strokes at 50% opacity on both surfaces, and original dashed
outer card outline. Latest requested refinement: dashed outline is white at 85%
opacity; glass-only backing is rendered at 88% opacity, text backing at 6%,
and empty artwork backing at 3%. Foreground content remains fully opaque.
Visual acceptance of this refinement is pending. No title bars or traffic-light buttons on the panels.
Settings also hides the traffic lights and provides a Done button.

### Always-active glass appearance (2026-09-10)

The nonactivating panels never become key, so `.ultraThinMaterial` and
`.glassEffect` were rendering their darker inactive appearance whenever another
app held focus, and only brightening on click. `FloatingPanel` now wraps its
hosted root view with `.environment(\.appearsActive, true)` (forces
`glassEffect` active rendering) and `.environment(\.materialActiveAppearance,
.active)` (forces `Material` active rendering). Both keys are settable in the
macOS 26.5 SDK; Debug build succeeds. Focus is unchanged — still
`.nonactivatingPanel`, `canBecomeKey` gated by `acceptsKeyboard`.

Follow-up: the environment values alone did not remove the inactive look — the
`.glassEffect(.clear)` layer (dominant, opacity 0.88) is backed by
`NSGlassEffectView`, which on macOS 26 has **no** active-state override
(confirmed against the 26.5 SDK header: only `style`, `cornerRadius`,
`tintColor`, `contentView`). It follows the host window's key appearance, which
is why the card brightened only on click (card can become key) and the launcher
never did. `NSVisualEffectView.state = .active` exists but would mean abandoning
Liquid Glass for the approved baseline. The initial `isKeyWindow` / `isMainWindow` overrides did not fix this:
user screenshots confirmed the glass still changed on click-away. The earlier
claim that these getters affect drawing only was not established and is withdrawn.

Follow-up (2026-09-10, 19:21): removed those overrides so actual key/main status
remains truthful. `FloatingPanel` now implements the undocumented Objective-C
`hasKeyAppearance` selector, returning true for both panels. This targets AppKit's
separate appearance query; nonactivating style and keyboard eligibility remain
unchanged. Existing SwiftUI clear Liquid Glass and accessibility fallbacks remain.
Prior art for this appearance hook: Chromium NativeWidgetMacNSWindow,
https://chromium.googlesource.com/experimental/chromium/src/+/refs/tags/73.0.3664.1/ui/views_bridge_mac/native_widget_mac_nswindow.mm
This is a private API compatibility dependency and needs verification after OS
updates. Full unsigned Debug build passed; app restarted in the background.
User confirmed the visual result: “perfect, now the visual is set.”
The clear Liquid Glass baseline is accepted; preserve this appearance hook.
Phase1 staging copy synced.


Built on macOS 26.6.2 with Xcode 26.6 (macOS 26.5 SDK), targeting macOS 26.0+.
Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the system developer
directory is unchanged. Observation macros require a build outside the agent sandbox.

## Offline interaction milestone implemented

- Two retained nonactivating floating panels; player 304 × 180 visible, pill 141 × 52.
- Launcher logo click opens or closes Settings (⌘/ shows or hides the card); group drag uses screen coordinates and a four-point threshold.
- Four 14-point corner handles, opposite-corner anchoring, minimum visible size 270 × 158,
  and per-display clamping. Sizes/fonts/art do not uniformly scale.
- Position and current size saved after a 400 ms debounce and on exit/sleep; explicit
  default-size preference is separate. Restore saves screen ID and relative position.
- Display-change recovery and saved-size preservation when the original display is absent.
- Pointer-position polling at 30 Hz makes transparent panel margins ignore mouse events
  and detects re-entry without event taps or screen recording. Paused during sleep;
  pinned during drag/resize. Rapid re-entry and Spaces still need hands-on checks.
- Carbon global shortcuts: Command+/ and Command+arrow keys (up, left, down, right). Registration failures
  appear in Settings. Unregistered on shutdown.
- Launcher and menu bar actions, native Settings, login-item service with actual status,
  and per-artwork ink choices (preview uses isolated artwork keys).
- Open Data Folder exports a readable preferences snapshot; authoritative settings use
  UserDefaults. No credentials are stored in this snapshot.
- Explicit playback preview defaults off; sample artwork and metadata are clearly labeled.
- Preview transport, 180 ms pressed feedback, seek drag/accessibility/arrow-key adjustment,
  interpolated progress, GIF frame delays and pause retention, rotating rim, particles,
  and sample Sabrina kiss variant. Preview generates no Spotify traffic or audio.
- Reduce Motion suppresses decorative animation; Reduce Transparency/Increase Contrast
  retain the semantic opaque backing. Card animations suspend when hidden or sleeping.

## Validation

- Full unsigned Debug Xcode build passed; app reopened.
- `Checks/GeometryChecks.swift`: four-corner anchoring across extreme deltas, negative
  screen coordinates, undersized displays, launcher spacing, and idempotent clamping passed.
- `Checks/PlaybackStateChecks.swift`: disconnected control guard, progress tick, pause,
  seek bounds, sample-track change, sleep/wake and preview shutdown passed.
- Compile geometry checks with WidgetGeometry.swift; playback checks with AppStore.swift.
- User accepted the static visual baseline; new event/animation behavior needs hands-on
  validation. Launch at Login is wired but was not enabled/tested on this unsigned temp build.
- Existing whitespace warning in Untitled.swift predates these edits and was left intact.

## Spotify authentication milestone implemented (phase 3)

- Compact scrollable Settings with Client ID save, Developer Dashboard link,
  exact redirect URI copy, Connect/Reconnect, Cancel Login, Disconnect and status.
  Setup opens automatically when no valid Client ID is configured.
- Browser PKCE with secure verifier/state, SHA-256 S256 challenge, fixed
  `http://127.0.0.1:8888/callback`, and the three planned playback scopes.
- Network.framework listener bound explicitly to loopback. Listener is ready
  before browser launch; validates request path, Host, state, duplicate parameters;
  limits headers to 8 KiB, concurrent connections to 8, connection lifetime to
  10 seconds, and login lifetime to five minutes. No codes/tokens logged.
- Keychain session storage, restore on launch, proactive refresh with a 60-second
  margin, coalescing, refresh-token retention, bounded retry and Retry-After.
- Session generation guards reject late work after cancellation, ID change,
  disconnect, sleep or shutdown. Disconnect disables restoration before Keychain
  deletion so a deletion error cannot silently reconnect on relaunch.
- Incoming/outgoing network capabilities enabled in both configurations. No ATS
  arbitrary-loads exception. Existing appearance/geometry and sample playback retained.
- Full unsigned Debug build passed. New authentication checks and real local
  loopback/isolated Keychain integration checks passed. See `SPOTIFY_SETUP.md`.
- Staged phase 3 sources: `/tmp/squidd-native-phase3`. Older phase 1/2 copies
  are historical and must not overwrite the newer authentication integration.

## Live Spotify milestone implemented (phase 4)

- Shared observable SpotifyPlayback controller drives both panels. AppStore routes
  preview locally and live actions to the controller; Preview Off restores live mode.
- One serialized worker polls the full playback-state endpoint at a configurable
  one-second interval. `GET /v1/me/player?additional_types=track,episode` intentionally
  replaces the planned currently-playing endpoint to include device restrictions
  in the same request. Hidden-card playback continues through the shared launcher.
- Exact previous/next/play/pause/seek APIs, command duplicate suppression, stale
  pre-command GET rejection and 400 ms reconciliation. Seek rolls back on failure.
- Device/item/action restrictions, track/episode/local/null/ad handling, one retry
  after 401, reconnect on persistent 401, 204 idle, 403 access diagnosis, 404 Open
  Spotify, Retry-After, quota halt and bounded transient backoff. No errors in titles.
- Monotonic 250 ms elapsed interpolation with duration clamp; no auto-skip at end.
- Shared 40-entry LRU of off-main decoded 300-pixel CGImage thumbnails. Bounded
  download size/time, stale artwork rejection and 30-second retry after image errors.
  Both artwork squares preserve their original frames and crossfade on updates.
- Synchronous auth session-change notification cancels and clears playback on
  disconnect/reconnect. Sleep, preview and app shutdown cancel worker/tick/art tasks.
- Settings shows live status and Open Spotify / Retry Playback. Launcher adds Open
  Spotify. Approved glass appearance hook and geometry remain unchanged.
- Full unsigned Debug build passed without new Swift warnings (only the existing
  AppIntents metadata-extraction note). Mock authentication/live playback, real PNG
  cache/decoding, preview state and geometry suites passed. No real account playback
  was exercised by the agent. Setup and acceptance instructions: `SPOTIFY_SETUP.md`.
- Current staging: `/tmp/squidd-native-phase4`. Do not restore older phase copies
  over the current authentication/playback implementation.

## AppleScript milestone implemented (phase 7, 2026-09-19)

The Spotify Web API is gone. Squidd now reads the Spotify app on this Mac over Apple Events,
which removes the development-mode allowlist that blocked App Store distribution, along with
the Client ID, the developer dashboard, OAuth/PKCE, the loopback listener, Keychain tokens,
rate limits, quota handling and the Premium requirement. Deleted: `SpotifyAuth.swift`,
`SpotifyLoopback.swift`, `SpotifyTokenStore.swift`, `SpotifyPlaybackAPI.swift` and
`Checks/SpotifyAuthChecks.swift`.

Two spike findings shaped the design, both measured against a signed sandboxed build:

- **Raw Apple Events, not `NSAppleScript`.** `NSAppleScript` costs ~62 ms median (163 ms max)
  per read and **deadlocks** on any thread but the main one — including a dedicated thread
  with a run loop — and a stuck call holds the AppleScript component lock for the whole
  process, so the main thread hangs too. `with timeout` does not prevent it. Precompiling
  saves nothing (66 ms fresh vs 62 ms precompiled): the cost is the round trip. Raw
  `NSAppleEventDescriptor` sends run off the main actor at ~8 ms median.
- **The notification is the data, not a trigger.** `com.spotify.client.PlaybackStateChanged`
  arrives with its `userInfo` intact under the App Sandbox — player state, track ID, name,
  artist, album, album artist, duration, playback position, has-artwork. So play, pause, skip
  and seek cost zero Apple Events and appear instantly. Apple Events remain for the artwork
  URL (once per track change), the state at launch, commands, and a slow safety net.

Also confirmed: duration arrives in **milliseconds** and position in **seconds** (Spotify's
sdef says duration is seconds — it is not); artwork URLs are the same `i.scdn.co` links the
Web API returned, so the artwork cache and per-artwork ink choices carry over unchanged.

Entitlements: `com.apple.security.scripting-targets` naming the two access groups Spotify
publishes (`com.spotify.playback`, `com.spotify.library`) is **sufficient on its own** — no
`temporary-exception.apple-events`, no `automation.apple-events`. Verified from a clean TCC
state; one consent prompt, then granted. `network.server` removed with the loopback listener.
`INFOPLIST_KEY_NSAppleEventsUsageDescription` added to both configurations.

`SpotifyPlaybackState` drops `.disconnected`, `.rateLimited` and `.quotaExceeded` and gains
`.notRunning`, `.permissionNeeded` and `.permissionDenied`. The launcher menu loses Connect /
Disconnect / Cancel Login. Settings ▸ Music loses the Client ID field, Save Client ID,
Developer Dashboard and redirect URI, and now shows status plus one contextual action (Open
Spotify / Allow Access / Open Settings). Settings opens at launch only when Automation
permission has never been requested.

Preserved: the approved glass appearance hook, geometry, the 250 ms interpolated clock,
`boost`/background/suspend behavior, the 400 ms post-command reconciliation, seek rollback,
artwork LRU and crossfade, and preview isolation.

Full unsigned Debug build passed with no new warnings. All check suites pass, including a new
opt-in `--integration` run against the real Spotify. Squidd never launches Spotify itself.

User confirmed the live result on 2026-09-19: "looks fine it changes what appears instantly
in the music player... works fast and its even better than before." Track changes made inside
Spotify reach the card with no visible lag, which is the notification path working as
intended.

Podcasts, from that same hands-on pass: **inconsistent, and not fixable here**. Some episodes
report duration, position and full transport; others report no duration at all, so the card
hides the scrubber and elapsed time and disables seeking while play/pause/skip keep working.
That is the zero-duration fallback behaving correctly (pinned by the `unknownLength` check),
not a defect — Spotify exposes no length for those episodes through either the scripting
interface or the notification, so there is no second source to consult. User's read: "its no
big deal."

Ads remain **unverified against a real ad**: the user has Premium and cannot produce one.
Detection keys off the `spotify:ad:` URI prefix and is covered only by synthetic payloads in
the checks. If the prefix ever differs, the failure is mild — the ad would show its own title
and the transport would stay enabled, which Spotify ignores during ads anyway.

Still open: the Settings ▸ Music tab is wired to the minimum that works — its 2.0 layout
belongs to the settings redesign, and the redesign assets `music-save-key-icon.svg` and
`music-go-to-dev-dash.svg` are now orphaned. Signed sandboxed runtime behavior and App Store
review of the Apple Events entitlement remain to be seen; Developer ID is the fallback.

## Next

Real-account acceptance for phases 3/4 remains: connect/consent, actual metadata and
artwork, play/pause/previous/next/seek, hidden-card updates, no active device,
relaunch without login, token refresh and logout. Mock tests cannot prove account
eligibility or live device behavior. Signed App Sandbox runtime also remains pending.

Phase 5 hands-on accessibility/lifecycle: resize handles, transparent click-through,
global shortcuts while another app is focused, GIF freeze/resume, VoiceOver/keyboard
seeking, Spaces/fullscreen, display removal, relaunch placement and Launch at Login;
then profile idle/playing resources and finish distribution handoff in phase 6.

## User verification and visual polish

- User confirmed real-account Spotify playback: “it works fine.”
- Removed the white shadow/glow from emitted music-note particles at user request.
  Particle motion and the launcher rim remain as implemented. Debug build passed.
