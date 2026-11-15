<p align="center">
  <img src=".github/assets/squidd-logo.png" alt="Squidd" width="149" />
</p>

<p align="center">
  <img src=".github/assets/get-for-mac.svg" alt="Get for Mac" width="242" />
</p>

<p align="center">
  <sub>Coming soon · macOS 26 or later</sub>
</p>

<br />

### Your song, always within reach

Squidd sits on your desktop in Liquid Glass, showing the album cover, song and artist, plus play, pause, skip and a seek bar. The pill above it can show the Squidd logo, the album cover, an animated mascot of your choice, or all three, and its rim glows while music plays.

Pick light or dark glass, recolor the logo and rim, and add a dashed outline or floating music notes. Press <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>/</kbd> to tuck the player away and keep just the pill, or add the arrow keys to glide it around your screen.

Squidd talks to the Spotify or Music app already running on your Mac, so there’s no account to connect.

### Run locally

Squidd is Mac only. You need macOS 26 or later and Xcode 26 or later. Run these in Terminal:

```bash
git clone https://github.com/misanode/Squidd.git
cd Squidd
xcodebuild -project Squidd.xcodeproj -scheme Squidd -configuration Release -derivedDataPath /tmp/squidd-build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open /tmp/squidd-build/Build/Products/Release/Squidd.app
```

Or open `Squidd.xcodeproj` in Xcode, choose your own team (or **Sign to Run Locally**) under Signing & Capabilities, and press Run.

The first time Squidd reads Spotify or Music, macOS asks whether it may control that app. Choose **OK**.
