#!/bin/bash
# Compiles main.swift into UltraWhisper.app, signs it, installs to /Applications.
set -e
cd "$(dirname "$0")"

APP="UltraWhisper.app"
BIN="$APP/Contents/MacOS/UltraWhisper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SRCS=(main.swift Capture.swift Panel.swift Proxy.swift)
swiftc -O -target arm64-apple-macos12.0  "${SRCS[@]}" -o "$BIN-arm64"
swiftc -O -target x86_64-apple-macos12.0 "${SRCS[@]}" -o "$BIN-x86_64"
lipo -create -output "$BIN" "$BIN-arm64" "$BIN-x86_64"
rm "$BIN-arm64" "$BIN-x86_64"

mkdir -p "$APP/Contents/Resources"
cp icon/UltraWhisper.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>UltraWhisper</string>
    <key>CFBundleDisplayName</key>     <string>UltraWhisper</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.ultrawhisper</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>UltraWhisper</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleIconFile</key>         <string>UltraWhisper</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>UltraWhisper records your voice while you hold the hotkey so it can transcribe it locally.</string>
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

pkill -x UltraWhisper 2>/dev/null || true
pkill -x whisper-server 2>/dev/null || true
pkill -f sherpa-onnx-offline-websocket-server 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "$STAGE/$APP" "/Applications/$APP"
echo "Installed to /Applications/$APP"
