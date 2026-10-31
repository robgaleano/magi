#!/usr/bin/env bash
set -euo pipefail

VENV="$HOME/llm/mlx-qwen38/.venv"
OUT_MAIN="$HOME/llm/mlx-qwen38/models/Swift-1.5-Qwen3.8-27B-8bit"
OUT_MTP="$HOME/llm/mlx-qwen38/models/Swift-1.5-Qwen3.8-27B-MTP-8bit"

mkdir -p "$HOME/llm/mlx-qwen38/models"

echo "================================================================"
echo " 🔑 Step 1/4: Checking Hugging Face Authentication"
echo "================================================================"
"$VENV/bin/hf" auth whoami

echo ""
echo "================================================================"
echo " 📥 Step 2/4: Downloading Official ukisai/Swift-1.5-Qwen3.8-27b (BF16)"
echo "================================================================"
export HF_XET_HIGH_PERFORMANCE=1
"$VENV/bin/hf" download ukisai/Swift-1.5-Qwen3.8-27b

echo ""
echo "================================================================"
echo " ⚙️  Step 3/4: Converting to 8-bit MLX + 8-bit MTP Drafter"
echo "================================================================"
rm -rf "$OUT_MAIN" "$OUT_MTP"
"$VENV/bin/python" -m mlx_vlm convert \
  --hf-path ukisai/Swift-1.5-Qwen3.8-27b \
  --mlx-path "$OUT_MAIN" \
  --mtp \
  --mtp-output "$OUT_MTP" \
  -q --q-bits 8 --q-group-size 64

echo ""
echo "================================================================"
echo " 📜 Step 4/4: Copying Official LICENSE, NOTICE & Apache-2.0 Files"
echo "================================================================"
SNAPSHOT_DIR=$(ls -d "$HOME/.cache/huggingface/hub/models--ukisai--Swift-1.5-Qwen3.8-27b/snapshots/"* | tail -n 1)
for target_dir in "$OUT_MAIN" "$OUT_MTP"; do
  for doc in LICENSE LICENSE-APACHE-2.0 NOTICE; do
    if [ -f "$SNAPSHOT_DIR/$doc" ]; then
      cp "$SNAPSHOT_DIR/$doc" "$target_dir/$doc"
    fi
  done
  cat >> "$target_dir/NOTICE" << 'EOF'

---
MLX 8-bit Quantization & MTP Drafter Split Notice (Swift Open License v1.0, Section 4(b)):
  - Converted and quantized to 8-bit MLX format (group_size=64, bits=8, mode=affine)
    with standalone Multi-Token Prediction (MTP) drafter extraction using mlx-vlm 0.7.8.
EOF
done

echo ""
echo "✅ CONVERSION COMPLETE:"
du -sh "$OUT_MAIN" "$OUT_MTP"
