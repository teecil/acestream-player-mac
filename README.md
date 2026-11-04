# AceStream Player for macOS

English | [Русский](README.ru.md)

A small Mac app for watching Ace Stream links. Paste an `acestream://` link, press Start, and the stream opens in IINA. Press Stop when you're done.

It runs the Ace Stream engine in Docker Desktop and plays the stream in IINA. Both get installed by the app on first launch, so you never need a terminal.

Needs an Apple Silicon Mac (M1 or newer) with macOS 14 or later and about 8 GB of free space.

The app is in English and Russian. It asks which one on first launch; you can switch later in the AceStream Player menu → Language.

## Install

1. Download `AceStreamPlayer.dmg` from [Releases](https://github.com/teecil/acestream-player-mac/releases/latest) and drag the app into Applications.
2. The app isn't signed with a paid Apple developer certificate, so macOS won't open it the first time. Go to System Settings → Privacy & Security, scroll down and click "Open Anyway".
3. Pick a language, then press "Install and set up". The app downloads IINA and Docker Desktop, about 1 GB, and asks for your Mac password once to install Docker. This takes 5–10 minutes and only happens once.

## Use

- Paste a link and press "Start stream". It takes 20–60 seconds, mostly waiting for Docker to boot.
- If a stream doesn't work, paste another link and press "Open". The current stream keeps playing until the new one actually starts. If the new one fails, you stay on the old one.
- Press "Stop" when you're done. The player closes and Docker shuts down, so nothing keeps running in the background. Quitting the app does the same.
- `acestream://` links clicked in a browser open in the app.

If something goes wrong, the log is at `~/Library/Logs/AceStreamPlayer/AceStreamPlayer.log` (Help → Show Log).

## How it works

- **Engine.** Ace Stream has no official Docker image, and their Linux engine only exists for x86_64. The app uses `jopsis/acestream:v3.2.17-fix`, which has an arm64 build of the engine, so it runs without emulation. If that one won't start, it falls back to Ace Link's `blaiseio/acelink` image (amd64, emulated) and remembers which one worked.
- **Docker Desktop** comes from docker.com and is installed with Docker's own unattended installer (`install --accept-license --user=…`). It only runs while you're watching. For the copy the app installed, start-at-login and the dashboard pop-up are turned off. A Docker Desktop you installed and started yourself is left alone.
- **IINA** comes from its GitHub releases. The app launches its own IINA process, so Stop never closes IINA windows you opened yourself.
- Before installing anything, the app checks it with Gatekeeper (`spctl --assess`) and makes sure the binary is arm64.
- The engine listens on 127.0.0.1 only, port 16878 or the next free one. Its container has the label `app.acestreamplayer.managed`; the app only ever removes containers with that label and never deletes images. The image is downloaded once (about 100 MB) and reused.
- Switching streams opens the new link as a second session in the same engine and only swaps players once the engine reports it is downloading.
- If the app crashes, a small watchdog script removes the container, closes the player and stops Docker. The next launch cleans up anything left over.

## Build

Needs macOS 14+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
swift test
./build.sh     # build/AceStream Player.app, build/AceStreamPlayer.dmg
```

GitHub Actions builds every push on an Apple Silicon runner. Pushing a `v*` tag publishes the DMG to Releases.

To check Docker, the engine image and the engine API without the app:

```bash
scripts/engine_smoke_test.sh               # engine starts and answers
scripts/engine_smoke_test.sh <content-id>  # plus a real stream
```

## Status

Early version. It builds and the unit tests pass in CI, but it hasn't been tested much on real Macs yet. Things to check by hand:

- language picker on first launch, switching language from the menu

- first-time setup on a Mac without Docker and IINA, then a second launch that downloads nothing
- a real stream plays; Stop closes IINA and the Docker whale disappears from the menu bar
- Open with a working link switches streams, Open with a dead link keeps the old one
- Docker doesn't start by itself after a reboot
- quitting the app or killing it with `kill -9` while watching leaves nothing running
- no internet, a bad link, a stream with no peers: each shows a readable error

## Limitations

- The engine image is a community build pinned to one version. To change it, edit `EngineImage` in [DockerService.swift](Sources/AceStreamPlayer/Services/DockerService.swift).
- Starting is slower than it could be, because Docker starts from scratch every time.
- Docker Desktop is free for personal use; the app accepts its license during install.
- To ship without the Gatekeeper warning you'd need a Developer ID certificate and notarization.
