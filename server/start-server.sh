#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BIN="$DIR/.venv/bin"

MODEL="${MODEL:-$DIR/models/Swift-1.5-Qwen3.8-27B-8bit}"
DRAFTER="${DRAFTER:-$DIR/models/Swift-1.5-Qwen3.8-27B-MTP-8bit}"
DRAFT_BLOCK_SIZE="${DRAFT_BLOCK_SIZE:-4}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
PRELOAD="${PRELOAD:-1}"
PREFILL_STEP="${PREFILL_STEP:-4096}"
MAX_TOKENS="${MAX_TOKENS:-32768}"
# Automatic Prefix Caching (APC), sized for a 128 GB Mac — lower APC_MEMORY_MAX_GB on smaller machines
export APC_ENABLED="${APC_ENABLED:-1}"
export APC_NUM_BLOCKS="${APC_NUM_BLOCKS:-16384}"
export APC_MEMORY_MAX_GB="${APC_MEMORY_MAX_GB:-32}"
export APC_DISK_MAX_GB="${APC_DISK_MAX_GB:-40}"
export APC_CHECKPOINT_ENTRIES="${APC_CHECKPOINT_ENTRIES:-24}"
export APC_CHECKPOINT_INTERVAL_TOKENS="${APC_CHECKPOINT_INTERVAL_TOKENS:-4096}"
export MLX_VLM_DEFAULT_MODEL="${MODEL}"
export MLX_VLM_DRAFT_MODEL="${DRAFTER}"
export MLX_VLM_MODEL_PATHS="${MODEL}"
# API key: every request (including /health and /v1/metrics) must send "Authorization: Bearer <key>".
KEY_FILE="${MAGI_API_KEY_FILE:-$HOME/.config/magi/api-key}"
if [[ -z "${MLX_VLM_SERVER_API_KEY:-}" && -r "$KEY_FILE" ]]; then
  MLX_VLM_SERVER_API_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
  export MLX_VLM_SERVER_API_KEY
fi
export MLX_VLM_DEFAULT_REASONING_EFFORT="${MLX_VLM_DEFAULT_REASONING_EFFORT:-xhigh}"
# GPU wired-memory limit while the model is loaded: total unified memory minus 16 GiB for macOS
export MLX_IOGPU_WIRED_LIMIT_MB="${MLX_IOGPU_WIRED_LIMIT_MB:-$(( $(/usr/sbin/sysctl -n hw.memsize) / 1048576 - 16384 ))}"
# Reserve 16 GiB for macOS and give 112 GiB (114,688 MB) to Metal/GPU when preloading
if [[ "$PRELOAD" == "1" ]]; then
  sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb="${MLX_IOGPU_WIRED_LIMIT_MB}" >/dev/null 2>&1 || true
fi
# KV_MODE options (benchmarked 2026-10-30 with MTP, 140K-token prompt):
#   f16        -> Uncompressed FP16 KV cache. FASTEST: 538 tok/s prefill, 15.0 tok/s decode, 73.7 GiB peak
#   q8         -> 8-bit KV after 8K tokens. Slower: 384 tok/s prefill, 10.3 tok/s decode, 92.3 GiB peak
#   turboquant -> K=8-bit + V=4-bit TurboQuant. BROKEN in mlx-vlm 0.7.8 server (mixed K/V schemes
#                 raise NotImplementedError on the batch path); symmetric 4-bit TurboQuant was also
#                 slower (398 tok/s prefill, 10.5 tok/s decode, 94.3 GiB peak)
KV_MODE="${KV_MODE:-f16}"

KV_ARGS=()
case "$KV_MODE" in
  f16)
    ;;
  q8)
    KV_ARGS=(--kv-bits 8 --kv-quant-scheme uniform --quantized-kv-start 8192)
    ;;
  turboquant)
    KV_ARGS=(
      --kv-bits 4
      --kv-key-scheme uniform --kv-key-bits 8
      --kv-value-scheme turboquant --kv-value-bits 4
      --quantized-kv-start 8192
    )
    ;;
  *)
    echo "Unknown KV_MODE: $KV_MODE (choose f16, q8, or turboquant)" >&2
    exit 1
    ;;
esac

DRAFT_ARGS=()
if [[ -n "$DRAFTER" ]]; then
  DRAFT_ARGS=(--draft-model "$DRAFTER" --draft-block-size "$DRAFT_BLOCK_SIZE")
fi

MODEL_ARGS=()
if [[ "$PRELOAD" == "1" ]]; then
  MODEL_ARGS=(--model "$MODEL")
fi

echo "============================================================"
echo " Starting MLX Server on http://${HOST}:${PORT}/v1 (preload=${PRELOAD})"
echo " Model            : ${MODEL}"
echo " Drafter          : ${DRAFTER:-none} (block_size=${DRAFT_BLOCK_SIZE})"
echo " KV Mode          : ${KV_MODE}"
echo " API key          : $([[ -n "${MLX_VLM_SERVER_API_KEY:-}" ]] && echo "required" || echo "NOT SET (any local web page can call the server)")"
echo " Prefix Caching   : APC_ENABLED=${APC_ENABLED} (blocks=${APC_NUM_BLOCKS}, checkpoints=${APC_CHECKPOINT_ENTRIES})"
echo "============================================================"

exec "$VENV_BIN/mlx_vlm.server" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  ${DRAFT_ARGS[@]+"${DRAFT_ARGS[@]}"} \
  --host "$HOST" \
  --port "$PORT" \
  --max-tokens "$MAX_TOKENS" \
  --prefill-step-size "$PREFILL_STEP" \
  ${KV_ARGS[@]+"${KV_ARGS[@]}"} \
  "$@"
