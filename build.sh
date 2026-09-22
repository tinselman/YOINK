#!/bin/bash
# Builds YOINK! with the Command Line Tools toolchain (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/YOINK!.app"
BIN="$APP/Contents/MacOS/YOINK"

# The bundle identifier is deliberately unchanged from the app's original name:
# macOS ties the Screen Recording grant to it, and renaming it would make the
# user approve the app all over again.
BUNDLE_ID="com.robynmiller.screen-capture"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>YOINK!</string>
    <key>CFBundleDisplayName</key>          <string>YOINK!</string>
    <key>CFBundleExecutable</key>           <string>YOINK</string>
    <key>CFBundleIdentifier</key>           <string>com.robynmiller.screen-capture</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>Robyn Miller</string>
</dict>
</plist>
PLIST

# Regenerate the icon if the drawing has changed, then install it.
if [ ! -f Resources/AppIcon.icns ] || [ Tools/makeicon.swift -nt Resources/AppIcon.icns ]; then
    mkdir -p build
    swift Tools/makeicon.swift >/dev/null
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc \
    -swift-version 5 \
    -O \
    -target arm64-apple-macos14.0 \
    -framework AppKit \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreGraphics \
    Sources/*.swift \
    -o "$BIN"

# Prefer a stable self-signed identity if one exists: TCC then binds the Screen
# Recording grant to the certificate rather than the binary hash, so rebuilding
# no longer revokes it. Falls back to ad-hoc signing.
IDENTITY="Local Codesign"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "Signed with '$IDENTITY' - your Screen Recording grant survives rebuilds."
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "Ad-hoc signed - macOS will ask you to re-approve Screen Recording after each build."
fi

echo "Built and installed: $APP"
