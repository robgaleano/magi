#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BIN="$DIR/.venv/bin"

MODEL="${MODEL:-$DIR/models/Swift-1.5-Qwen3.8-27B-8bit}"
DRAFTER="${DRAFTER:-$DIR/models/Swift-1.5-Qwen3.8-27B-MTP-8bit}"
DRAFT_BLOCK_SIZE="${DRAFT_BLOCK_SIZE:-4}"
PROMPT="${1:-Write a complete, well-typed Python async HTTP client class using httpx with exponential backoff retries, circuit breaker state, and unit tests.}"
MAX_TOKENS="${MAX_TOKENS:-400}"

echo "============================================================"
echo " 1/3: Baseline (8-bit, NO speculative drafter)"
echo "============================================================"
"$VENV_BIN/mlx_vlm.generate" \
  --model "$MODEL" \
  --prompt "$PROMPT" \
  --max-tokens "$MAX_TOKENS" \
  --temperature 0.0 \
  --verbose

echo ""
echo "============================================================"
echo " 2/3: MTP Speculative Decoding (8-bit + MTP-8bit drafter)"
echo "============================================================"
"$VENV_BIN/mlx_vlm.generate" \
  --model "$MODEL" \
  --draft-model "$DRAFTER" \
  --draft-block-size "$DRAFT_BLOCK_SIZE" \
  --prompt "$PROMPT" \
  --max-tokens "$MAX_TOKENS" \
  --temperature 0.0 \
  --verbose

echo ""
echo "============================================================"
echo " 3/3: MTP + Asymmetric TurboQuant KV Cache (K=8b, V=4b TQ)"
echo "============================================================"
"$VENV_BIN/mlx_vlm.generate" \
  --model "$MODEL" \
  --draft-model "$DRAFTER" \
  --draft-block-size "$DRAFT_BLOCK_SIZE" \
  --kv-bits 4 \
  --kv-key-scheme uniform --kv-key-bits 8 \
  --kv-value-scheme turboquant --kv-value-bits 4 \
  --quantized-kv-start 256 \
  --prompt "$PROMPT" \
  --max-tokens "$MAX_TOKENS" \
  --temperature 0.0 \
  --verbose
