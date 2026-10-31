#!/usr/bin/env bash
set -euo pipefail

VENV="$HOME/llm/mlx-qwen38/.venv"
OUT_MAIN="$HOME/llm/mlx-qwen38/models/Swift-1.5-Qwen3.8-27B-8bit"
OUT_MTP="$HOME/llm/mlx-qwen38/models/Swift-1.5-Qwen3.8-27B-MTP-8bit"
REPO_MAIN="robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit"
REPO_MTP="robgaleano/Swift-1.5-Qwen3.8-27B-MTP-MLX-8bit"

echo "================================================================"
echo " 🔍 1/3: Verifying Converted 8-bit MLX Shards & Tensor Counts"
echo "================================================================"
ls -lh "$OUT_MAIN"/*.safetensors "$OUT_MTP"/*.safetensors

"$VENV/bin/python" -c "
import json
from safetensors import safe_open

with open('$OUT_MAIN/model.safetensors.index.json') as f:
    idx = json.load(f)['weight_map']
with open('$OUT_MAIN/config.json') as f:
    cfg = json.load(f)
with safe_open('$OUT_MTP/model.safetensors', framework='mlx') as f:
    mtp_keys = list(f.keys())

print(f'✓ Main Model Quantization: {cfg.get(\"quantization\")}')
print(f'✓ Main Model Tensor Count: {len(idx)} tensors across 6 shards')
print(f'✓ MTP Drafter Tensor Count: {len(mtp_keys)} tensors')
"

echo ""
echo "================================================================"
echo " ☁️  2/3: Uploading MTP Drafter -> https://huggingface.co/$REPO_MTP"
echo "================================================================"
export HF_XET_HIGH_PERFORMANCE=1
"$VENV/bin/hf" repos create "$REPO_MTP" --type model --exist-ok
"$VENV/bin/hf" upload "$REPO_MTP" "$OUT_MTP" . --commit-message "Upload 8-bit MLX MTP speculative drafter for UkisAI Swift-1.5-Qwen3.8-27B"

echo ""
echo "================================================================"
echo " ☁️  3/3: Uploading Main 8-bit Model -> https://huggingface.co/$REPO_MAIN"
echo "================================================================"
"$VENV/bin/hf" repos create "$REPO_MAIN" --type model --exist-ok
"$VENV/bin/hf" upload "$REPO_MAIN" "$OUT_MAIN" . --commit-message "Upload 8-bit MLX conversion of UkisAI Swift-1.5-Qwen3.8-27B (mlx-vlm 0.7.8)"

echo ""
echo "🎉 UPLOAD COMPLETE:"
echo "  • Main Model:  https://huggingface.co/$REPO_MAIN"
echo "  • MTP Drafter: https://huggingface.co/$REPO_MTP"
