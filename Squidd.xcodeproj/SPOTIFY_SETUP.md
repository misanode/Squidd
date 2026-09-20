# Spotify setup and live playback

Squidd reads the Spotify app running on this Mac over Apple Events. There is no account to
connect, no Client ID, no developer dashboard and no Premium requirement.

## Setup

1. Open Spotify and play something.
2. The first time Squidd reads it, macOS asks whether Squidd may control Spotify. Choose
   **OK**. Squidd Settings ▸ Music can ask for this deliberately with **Allow Access**.
3. That's it. The card and launcher follow whatever Spotify is playing.

If you choose **Don't Allow**, Settings ▸ Music shows the refusal and offers **Open
Settings**, which opens Privacy & Security ▸ Automation, where Squidd can be re-enabled. Only
you can undo a refusal — macOS will not ask a second time.

## What this covers, and what it doesn't

Squidd shows the Spotify **app on this Mac**. Playing from a phone, a speaker or the web
player does not appear here — that is the one thing the old Web API version could do that
this cannot. In exchange there is no setup, no login that expires, no rate limits and no
account eligibility to worry about.

Podcast episodes come through as whatever Spotify's scripting interface reports, which is
thinner than the Web API's episode metadata and inconsistent between episodes: some carry
duration, position and full transport, while others report no duration, so the scrubber and
elapsed time are hidden and seeking is disabled while play/pause/skip still work. Spotify
exposes no length for those episodes through either route, so there is nothing to fall back
on.

Ads are recognised (their track ID starts `spotify:ad:`), labelled **Advertisement**, and the
transport controls are disabled for their duration — though this is verified only against
synthetic payloads in the checks, never a real ad. Local files play and seek normally but
have no album art.

**Squidd requires the Spotify desktop app.** It is built around Spotify specifically and does
not read Apple Music or any other player.

## How it works

Spotify broadcasts a `com.spotify.client.PlaybackStateChanged` distributed notification on
every play, pause, skip and seek, and its `userInfo` carries the whole snapshot: player
state, track ID, name, artist, album, duration and position. The App Sandbox does not strip
it, so nearly every update Squidd draws costs no Apple Event at all and appears instantly.

Apple Events fill the gaps:

- The **artwork URL**, the one field the notification omits. Fetched once per track change,
  about 8 ms, off the main actor.
- The **state at launch**, before any notification has been broadcast.
- **Commands** — play, pause, next, previous, and seek.
- A **slow safety-net poll** (15 s playing, 30 s otherwise, 60 s while the card is hidden)
  covering anything a missed notification would strand. Squidd also reads quickly for a
  moment after Spotify launches or activates, the card opens, or the screen comes back.

These are raw `NSAppleEventDescriptor` sends, deliberately not `NSAppleScript`. Measured
here, `NSAppleScript` costs ~62 ms a read and **deadlocks** on any thread but the main one —
even one with a run loop — and a stuck call takes the whole process's AppleScript component
with it. Raw events run off the main actor and cost ~8 ms.

Squidd never launches Spotify on its own: every send is gated on Spotify already running.

Durations arrive in **milliseconds** and positions in **seconds**, from both the notification
and the Apple Event, despite Spotify's dictionary describing duration as seconds. The
progress bar interpolates locally on a 250 ms tick between readings.

## Entitlements

`com.apple.security.scripting-targets` names the two access groups Spotify publishes in its
scripting definition — `com.spotify.playback` for the application class, `com.spotify.library`
for the track class. This is the sanctioned App Sandbox mechanism; no temporary exception is
needed, which was confirmed against a signed sandboxed build from a clean permission state.
`NSAppleEventsUsageDescription` supplies the text in the macOS prompt.

`com.apple.security.network.client` remains, for album art from `i.scdn.co` — the same image
URLs the Web API returned. `com.apple.security.network.server` is gone with the OAuth
loopback listener.

## Checks performed

- Snapshot values: millisecond durations, second positions, clamping past the end, ads,
  local files, stopped, playing-with-no-metadata, and unknown-length tracks.
- Notification parsing: a captured real payload, paused, stopped, missing player state,
  sparse payloads, `Has Artwork: 0`, ads, and awkward track titles.
- Apple Event error codes mapped to states: -1743 permission, -600/-609 not running,
  -1712 timeout, -1728 nothing loaded.
- Controller: opening read, serialized commands, dropped duplicates, stale-read rejection,
  notification-driven updates with no read, artwork fetched once per track rather than per
  broadcast, seek preview and rollback, seek clamping, closed Spotify, refused permission
  not retried in a loop, transient failure and recovery, preview and sleep isolation.
- Real PNG artwork decoding, LRU eviction and stale-image rejection (unchanged).
- Geometry and preview playback regressions (unchanged).
- Full unsigned Debug build.

Run everything with:

```sh
bash Checks/run-swift-checks.sh
```

Add the live option to drive the Spotify actually running on this Mac:

```sh
/tmp/squidd-live-playback-checks --integration
```

It needs Spotify open with a track loaded, pauses and resumes once (briefly audible) and
seeks to the position the track is already at (not audible). Apple Events sent from a
terminal are attributed to that terminal, so any permission prompt names the terminal rather
than Squidd.

## Hands-on acceptance

With Spotify playing, check title, artist, both artwork squares, elapsed time, play/pause,
previous/next and seeking. Change tracks inside Spotify and confirm the card keeps up with no
visible lag. Hide the card and confirm the launcher keeps updating. Then quit Spotify while
playing, relaunch it, and check an ad, a local file, a podcast, sleep/wake, and a Squidd
relaunch with no setup at all.
