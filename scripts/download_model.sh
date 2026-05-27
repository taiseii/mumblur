#!/usr/bin/env bash
# Downloads the Whisper GGUF used by mumbler into ./models/.
# Idempotent: skips download if the file already exists.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODEL_NAME="${1:-ggml-large-v3-turbo-q5_0.bin}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"
MODEL_DIR="$ROOT/models"
DEST="$MODEL_DIR/$MODEL_NAME"

mkdir -p "$MODEL_DIR"
if [[ -f "$DEST" ]]; then
    echo "model already present: $DEST"
    exit 0
fi

echo "downloading $MODEL_NAME …"
curl -L --fail --progress-bar -o "$DEST.partial" "$MODEL_URL"
mv "$DEST.partial" "$DEST"
echo "wrote $DEST ($(du -h "$DEST" | cut -f1))"
