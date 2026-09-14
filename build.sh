#!/bin/bash
# Compiles Whisper via SwiftPM, signs it, installs to /Applications.
set -e
cd "$(dirname "$0")"

APP="Whisper.app"
BIN="$APP/Contents/MacOS/Whisper"

swift build -c release --product Whisper --arch arm64
REL="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REL/Whisper" "$BIN"

mkdir -p "$APP/Contents/Resources"
cp icon/Whisper.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Whisper</string>
    <key>CFBundleDisplayName</key>     <string>Whisper</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.whisper</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Whisper</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleIconFile</key>         <string>Whisper</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whisper records your voice while you hold the hotkey so it can transcribe it locally.</string>
</dict>
</plist>
PLIST
echo "Built $APP"

# Sign with a stable local cert so macOS keeps the mic + accessibility grants
# across rebuilds (an ad-hoc signature changes every build and resets them).
# Signing happens in a temp dir because this repo is under iCloud-synced Desktop.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Postit Dev"'; then
    codesign --force -s "Postit Dev" "$STAGE/$APP"
else
    codesign --force -s - "$STAGE/$APP"
fi

pkill -x Whisper 2>/dev/null || true
pkill -x whisper-server 2>/dev/null || true
pkill -f sherpa-onnx-offline-websocket-server 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "$STAGE/$APP" "/Applications/$APP"
echo "Installed to /Applications/$APP"
