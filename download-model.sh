#!/bin/bash
# Downloads speech models into ~/.config/ultrawhisper/.
# Usage:
#   ./download-model.sh parakeet    # NVIDIA Parakeet TDT v3 CoreML via FluidAudio (default)
#   ./download-model.sh base.en     # whisper.cpp fallback model (also: small.en, medium.en, large-v3-turbo)
set -e
NAME="${1:-parakeet}"
DIR="$HOME/.config/ultrawhisper"
mkdir -p "$DIR/models"

if [ "$NAME" = "parakeet" ]; then
    echo "Parakeet CoreML is downloaded by UltraWhisper on first launch"
    echo "(Fluid Inference, Hugging Face: FluidInference/parakeet-tdt-0.6b-v3-coreml)."
    echo "Open the app once with a network connection, then it stays local."
    exit 0
fi

curl -L --fail --progress-bar -o "$DIR/models/ggml-$NAME.bin.part" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$NAME.bin"
mv "$DIR/models/ggml-$NAME.bin.part" "$DIR/models/ggml-$NAME.bin"
echo "Saved $DIR/models/ggml-$NAME.bin"
[ "$NAME" != "base.en" ] && echo "Now set \"modelPath\" in ~/.config/ultrawhisper/config.json to that file."
exit 0
