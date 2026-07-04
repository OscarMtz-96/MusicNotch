# Music Visualizer

Minimal macOS notch music visualizer inspired by Dynamic Island/Boring Notch.

It shows the current system media metadata using `MediaRemoteAdapter`, including album art, title, artist, playback controls, a visualizer, and an interactive progress bar.

## Run locally

```sh
swift run MusicVisualizer
```

## Check

```sh
swift build
swift run MusicVisualizerSelfCheck
```

## Build the DMG

```sh
./scripts/package-dmg.sh
```

The installer is created at:

```sh
dist/Music Visualizer.dmg
```

## GitHub release

Push a version tag like `v0.1.0`. GitHub Actions will build the release app and attach `Music Visualizer.dmg` to the GitHub release.

