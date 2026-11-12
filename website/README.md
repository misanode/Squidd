# Squidd website

A static site made of HTML, CSS and JavaScript. It needs no build step.

```sh
cd website
python3 -m http.server 8000
```

## Notes

- The "Get for Mac" buttons are for show only. Clicking one shows a "Coming soon" note. Point the `data-get` links at a real download once a release exists.
- The pill and player in every preview are built in HTML and CSS to match `ContentView.swift` and `PlaybackViews.swift`. They're set up like the real app: Ghosting by TOMORROW X TOGETHER, the Charizard mascot, Dark appearance, outline off and music notes on.
- `assets/wallpaper-squidd.svg` is the Squidd pattern wallpaper exported from Figma (`squidd-preview-wallpaper.svg` in the repo root).
- `assets/ghosting-cover.jpg` is the album cover from Apple's iTunes Search API. `assets/mascot-charizard.gif` is the mascot GIF, and `mascot-charizard-still.png` is its first frame, shown while paused.
- `assets/settings/` holds icons copied from the app's asset catalog. `assets/squidd-logo.png` and `assets/get-for-mac.svg` come from the repo root, and `assets/dock/squidd.png` is the app icon.
- `assets/logos/spotify.svg` is the Spotify icon from the app's asset catalog. `assets/logos/apple-music.png` is the macOS Music app icon. Both are trademarks of their owners, used here only to show compatibility.
- **Third-party assets:** the album cover belongs to its label. Charizard is a Pokémon character. The Apple icons in `assets/dock/` (except `squidd.png`) and the SF Symbols in `assets/menubar/` are © Apple Inc. and were copied from the Lil Agent site's desktop mockup.
