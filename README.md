# YOINK!

A small macOS screen recorder. You pick a window, press GO, and it records that
region of the screen together with the computer's stereo system audio, saving a
QuickTime `.mov`.

- **Window mode** — click any window on screen to choose it. The rest of the
  screen darkens; the chosen area stays clear and is what gets recorded. Because
  it captures the *screen region* rather than the window's own surface, menus,
  popovers and anything else drawn over that area are captured too.
- **Fullscreen mode** — records the whole display. Chosen from the menu; the two
  modes are mutually exclusive.
- The controls and the dimming overlay are excluded from the capture, so they
  never appear in the recording.

Output: H.264 video at the display's native scale, AAC stereo audio at 48 kHz,
in a `.mov` container. Files land in `~/Movies` unless another folder is chosen
from **Recording › Save Location**.

## Getting it

There is no signed download yet, so build it yourself - it takes a few seconds
and needs no Xcode project:

```bash
git clone https://github.com/YOURNAME/yoink.git
cd yoink
./build.sh
```

That installs `YOINK!.app` into `/Applications`. Open it and grant Screen
Recording when macOS asks; the app waits and starts on its own once you do.

Because you compiled it on your own machine it is signed locally, so Gatekeeper
raises no objection.

## Using it

1. Open YOINK! - the screen dims and every window becomes selectable.
2. Click a window. It stays outlined, and **GO** / **OFF** appear beneath it.
3. Choose how much to take:
   - **NO BORDER** - the window without its title bar (the default)
   - **BORDER** - the whole window frame
   - **DRAG SELECT** - draw any rectangle and reshape it by its handles; it
     snaps to window edges, which is how you exclude a browser's tab bar
4. Press **GO**. The rest of the screen darkens and recording begins.
5. Press **STOP**. The file is saved and revealed in Finder.

**OFF** quits. **Recording › Fullscreen Record** switches to whole-screen
capture, and **Recording › Save Location** changes where files land.

## Requirements

- macOS 14 or later (uses ScreenCaptureKit for both video and system audio)
- Apple Silicon — the build script targets `arm64` only. For a universal binary,
  build twice and `lipo` the results together.
- Xcode Command Line Tools. Full Xcode is not needed; there is no Xcode project.

## Building

```bash
./build.sh
```

That compiles the Swift sources with `swiftc`, assembles the `.app` bundle by
hand, signs it, and installs it to `/Applications/YOINK!.app`.

Signing: if a code-signing identity named `Local Codesign` exists in the
keychain it is used, otherwise the build falls back to ad-hoc signing. This
matters more than it looks — see below.

## Layout

| File | Role |
| --- | --- |
| `main.swift` | Entry point |
| `AppDelegate.swift` | App lifecycle, permission flow, menus, recording state |
| `Recorder.swift` | `SCStream` capture and `AVAssetWriter` muxing |
| `Overlays.swift` | Window picker overlay and the dimming overlay |
| `Controls.swift` | The floating GO / OFF panel |
| `ReelView.swift` | The reel-to-reel indicator |
| `Support.swift` | Coordinate conversion, preferences, palette, window levels |
| `Splash.swift` | Opening screen, which doubles as the permission-wait status |
| `Tools/makeicon.swift` | Draws `Resources/AppIcon.icns`; run by `build.sh` when it changes |

One thing worth knowing if you touch `Overlays.swift` or `Recorder.swift`:
ScreenCaptureKit and CoreGraphics use a top-left origin, AppKit uses bottom-left.
`Coord.flip` converts between them and is its own inverse.

## Screen Recording permission

The app cannot do anything without the Screen Recording permission, and there
are two traps worth knowing about.

**`CGRequestScreenCaptureAccess()` is what shows the prompt.** Touching
ScreenCaptureKit alone does not prompt — it simply fails with `-3801`, "The user
declined TCCs". Call it exactly once: calling it repeatedly dismisses the prompt
macOS is trying to display.

**With ad-hoc signing, every rebuild revokes the grant.** macOS binds the
permission to the code's designated requirement. Ad-hoc signed code is
identified by its `cdhash`, which changes whenever the binary changes, so each
rebuild silently invalidates the user's approval — the toggle in System Settings
still *reads* as on while the app is denied. Signing with a certificate instead
binds the grant to the certificate, and rebuilds stop mattering:

```
designated => identifier "com.robynmiller.screen-capture"
              and certificate leaf = H"..."
```

For local development a self-signed certificate is enough. Create one in
Keychain Access via **Certificate Assistant › Create a Certificate**, named
`Local Codesign`, identity type *Self Signed Root*, certificate type *Code
Signing*, then trust it for code signing. `build.sh` picks it up automatically.

## Shipping this publicly

> **Notarize the built app, never this source archive.** Apple's notary service
> operates on a signed `.app`. Submitting the source zip fails with "has no
> signed executables or bundles" - there is no binary in it. Run `./build.sh`
> first, sign what it produces, and submit a zip made from *that*.

The app is currently signed for local use only; Gatekeeper rejects it on any
other Mac. To distribute it you need an Apple Developer Program membership and:

1. **Sign with Developer ID and enable the hardened runtime** (notarization
   requires it — the local build has no runtime flag set):

   ```bash
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: NAME (TEAMID)" \
     "/Applications/YOINK!.app"
   ```

2. **Notarize and staple:**

   ```bash
   ditto -c -k --keepParent "/Applications/YOINK!.app" YOINK.zip
   xcrun notarytool submit YOINK.zip --keychain-profile "notary" --wait
   xcrun stapler staple "/Applications/YOINK!.app"
   ```

   Credentials are stored once with `xcrun notarytool store-credentials`, using
   an app-specific password from appleid.apple.com.

3. **Package as a `.dmg`**, then sign, notarize and staple the disk image too —
   not just the app inside it.

One wrinkle worth knowing: `CFBundleIdentifier` is still
`com.robynmiller.screen-capture`, from before the app was renamed. It was left
alone deliberately - macOS ties the Screen Recording grant to it, so changing it
makes every existing user approve the app again. Change it at the same time as
the first signed release, not before.

The Mac App Store is not a realistic target — sandbox restrictions make screen
recorders effectively impossible to ship there. Direct download is the norm for
this category.

Users will still have to grant Screen Recording themselves in System Settings.
No certificate avoids that; it is enforced by TCC. What Developer ID signing
does buy them is that the grant survives app updates.
