#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv-nllb"
MODELS_DIR="$ROOT/models"
MODEL_ID="skywood/nllb-200-distilled-600M-ct2-int8"
MODEL_DIR="$MODELS_DIR/nllb-200-distilled-600M-ct2-int8"
TOKENIZER_ID="facebook/nllb-200-distilled-600M"
TOKENIZER_DIR="$MODELS_DIR/nllb-200-distilled-600M-tokenizer"

mkdir -p "$MODELS_DIR"

python3 -m venv "$VENV"
source "$VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install ctranslate2 transformers sentencepiece huggingface_hub

python - <<PY
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="$MODEL_ID",
    local_dir="$MODEL_DIR",
    local_dir_use_symlinks=False,
)

snapshot_download(
    repo_id="$TOKENIZER_ID",
    local_dir="$TOKENIZER_DIR",
    local_dir_use_symlinks=False,
    allow_patterns=[
        "tokenizer.json",
        "sentencepiece.bpe.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
    ],
)

print("Model downloaded to:", "$MODEL_DIR")
print("Tokenizer downloaded to:", "$TOKENIZER_DIR")
PY

echo ""
echo "Use this command in Settings -> Local Command:"
echo "\"$VENV/bin/python\" \"$ROOT/scripts/nllb_translate.py\" --models-dir \"$MODELS_DIR/nllb-200-distilled-600M-ct2-int8\" --tokenizer-dir \"$MODELS_DIR/nllb-200-distilled-600M-tokenizer\" --src {src} --dst {dst}"

defaults write com.example.TranslateToRu models_path "$MODELS_DIR"
echo "Saved models path in defaults: $MODELS_DIR"

defaults write com.example.TranslateToRu scripts_path "$ROOT/scripts"
echo "Saved scripts path in defaults: $ROOT/scripts"
