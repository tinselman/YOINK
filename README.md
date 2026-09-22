# YOINK!

A macOS screen recorder. Pick a window, press GO, get a QuickTime file with sound.

## Install

```bash
git clone https://github.com/tinselman/YOINK.git
cd YOINK
./build.sh
```

Installs `YOINK!.app` into `/Applications`. Open it and allow Screen Recording
when macOS asks — it starts by itself once you do.

Needs macOS 14+, Apple Silicon, and Xcode Command Line Tools (`xcode-select --install`).

## Use

1. Open YOINK! The screen dims and windows become selectable.
2. Click a window. **GO** and **OFF** appear beneath it.
3. **GO** to record, **STOP** to finish. **OFF** quits.

Files land in `~/Movies` as `.mov`, with the computer's stereo audio.

How much of the window to take:

| | |
| --- | --- |
| **NO BORDER** | the window without its title bar (default) |
| **BORDER** | the whole window |
| **DRAG SELECT** | draw any rectangle; drag its handles, snaps to window edges |

Menu: Fullscreen Record · Save Location · Choose Window (⌘K) · Start/Stop (⌘R)

## Notes

H.264 at native resolution, AAC stereo at 48 kHz. The controls and the dimming
never appear in the recording.

Building it yourself means it is signed on your own Mac, so Gatekeeper stays
quiet. [DEVELOPING.md](DEVELOPING.md) covers the code, the permission traps, and
how to sign and notarize it for release.

MIT licensed.
