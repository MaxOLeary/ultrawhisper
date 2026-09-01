#!/bin/bash
# Downloads speech models into ~/.config/ultrawhisper/.
# Usage:
#   ./download-model.sh parakeet    # NVIDIA Parakeet TDT 0.6B v3 + sherpa-onnx runtime (default engine)
#   ./download-model.sh base.en     # whisper.cpp fallback model (also: small.en, medium.en, large-v3-turbo)
set -e
NAME="${1:-parakeet}"
DIR="$HOME/.config/ultrawhisper"
mkdir -p "$DIR/models"

# fetch_tar <url> <archive-path> <extract-dir>: atomic download, then unpack.
fetch_tar() {
    curl -L --fail --progress-bar -o "$2.part" "$1"
    mv "$2.part" "$2"
    tar xf "$2" -C "$3"
    rm "$2"
}

if [ "$NAME" = "parakeet" ]; then
    SHERPA_VER="v1.13.6"
    SHERPA_PKG="sherpa-onnx-$SHERPA_VER-onnxruntime-1.27.1-osx-arm64-shared"
    if [ ! -x "$DIR/sherpa-onnx/bin/sherpa-onnx-offline-websocket-server" ]; then
        echo "Downloading sherpa-onnx runtime..."
        fetch_tar "https://github.com/k2-fsa/sherpa-onnx/releases/download/$SHERPA_VER/$SHERPA_PKG.tar.bz2" \
                  "$DIR/sherpa.tar.bz2" "$DIR"
        rm -rf "$DIR/sherpa-onnx"
        mv "$DIR/$SHERPA_PKG" "$DIR/sherpa-onnx"
    fi
    MODEL="sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    if [ ! -f "$DIR/models/$MODEL/encoder.int8.onnx" ]; then
        echo "Downloading Parakeet TDT 0.6B v3 (~650 MB)..."
        fetch_tar "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL.tar.bz2" \
                  "$DIR/models/pk.tar.bz2" "$DIR/models"
    fi
    echo "Parakeet ready at $DIR/models/$MODEL"
    exit 0
fi

curl -L --fail --progress-bar -o "$DIR/models/ggml-$NAME.bin.part" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$NAME.bin"
mv "$DIR/models/ggml-$NAME.bin.part" "$DIR/models/ggml-$NAME.bin"
echo "Saved $DIR/models/ggml-$NAME.bin"
[ "$NAME" != "base.en" ] && echo "Now set \"modelPath\" in ~/.config/ultrawhisper/config.json to that file."
exit 0
