#!/bin/bash
# icon.svg -> Whisper.icns (all Dock/Finder sizes). Run from icon/.
# render.swift is the WebKit SVG renderer (copied from postit/Swift/icon).
set -e
cd "$(dirname "$0")"
swift render.swift icon.svg icon-1024.png
rm -rf Whisper.iconset && mkdir Whisper.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out Whisper.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2))
  sips -z $d $d icon-1024.png --out Whisper.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns Whisper.iconset -o Whisper.icns
rm -rf Whisper.iconset
echo "wrote Whisper.icns"
