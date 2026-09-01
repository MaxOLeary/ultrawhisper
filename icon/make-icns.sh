#!/bin/bash
# icon.svg -> UltraWhisper.icns (all Dock/Finder sizes). Run from icon/.
# Uses the shared WebKit SVG renderer from the postit project.
set -e
cd "$(dirname "$0")"
swift ../../postit/Swift/icon/render.swift icon.svg icon-1024.png
rm -rf UltraWhisper.iconset && mkdir UltraWhisper.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out UltraWhisper.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2))
  sips -z $d $d icon-1024.png --out UltraWhisper.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns UltraWhisper.iconset -o UltraWhisper.icns
rm -rf UltraWhisper.iconset
echo "wrote UltraWhisper.icns"
