#!/bin/bash
set -euo pipefail
# Optional source directory lets staged changes be checked before installation.
checks_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:-$checks_dir/../../Squidd}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
compiler=(xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -swift-version 5
  -default-isolation MainActor -module-cache-path /tmp/squidd-swift-cache)
playback_sources=("$source_dir/SpotifyBridge.swift" "$source_dir/NowPlaying.swift" "$source_dir/AppleMusicBridge.swift" "$source_dir/Playback.swift" "$source_dir/ArtworkCache.swift")
"${compiler[@]}" "${playback_sources[@]}" "$checks_dir/SpotifyPlaybackChecks.swift" -o /tmp/squidd-live-playback-checks
/tmp/squidd-live-playback-checks
"${compiler[@]}" "${playback_sources[@]}" "$source_dir/AppStore.swift" "$checks_dir/PlaybackStateChecks.swift" -o /tmp/squidd-playback-checks
/tmp/squidd-playback-checks
"${compiler[@]}" "$source_dir/WidgetGeometry.swift" "$checks_dir/GeometryChecks.swift" -o /tmp/squidd-geometry-checks
/tmp/squidd-geometry-checks
