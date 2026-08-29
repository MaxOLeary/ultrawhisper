#!/bin/bash
# Downloads a whisper.cpp model into ~/.config/ultrawhisper/models/.
# Usage: ./download-model.sh [small.en]   (also: base.en, medium.en, large-v3-turbo)
set -e
NAME="${1:-small.en}"
DIR="$HOME/.config/ultrawhisper/models"
mkdir -p "$DIR"
curl -L --fail --progress-bar -o "$DIR/ggml-$NAME.bin.part" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$NAME.bin"
mv "$DIR/ggml-$NAME.bin.part" "$DIR/ggml-$NAME.bin"
echo "Saved $DIR/ggml-$NAME.bin"
[ "$NAME" != "small.en" ] && echo "Now set \"modelPath\" in ~/.config/ultrawhisper/config.json to that file."
exit 0
