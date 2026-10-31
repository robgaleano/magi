#!/usr/bin/env bash
# Installs the MLX server (mlx-vlm 0.7.8 + local patches) into $MLX_HOME and
# registers it as a launchd user agent. Safe to re-run.
#
#   ./server/install.sh                 # copy scripts, set up venv, download models, start service
#   ./server/install.sh --link          # symlink scripts to this repo instead (edits are tracked by git)
#   ./server/install.sh --skip-models   # don't download the ~30 GB of weights
#   ./server/install.sh --skip-venv     # keep the existing Python environment as-is
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_HOME="${MLX_HOME:-$HOME/llm/mlx-qwen38}"
MODE=copy
SKIP_MODELS=0
SKIP_VENV=0

for arg in "$@"; do
  case "$arg" in
    --link) MODE=link ;;
    --skip-models) SKIP_MODELS=1 ;;
    --skip-venv) SKIP_VENV=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

reload_agent() {  # reload_agent <label> <plist>: (re)load a LaunchAgent, waiting for the old one to unload
  local target="gui/$(id -u)/$1"
  if launchctl print "$target" >/dev/null 2>&1; then
    launchctl bootout "$target" 2>/dev/null || true
    for _ in $(seq 1 20); do launchctl print "$target" >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  for _ in 1 2 3; do launchctl bootstrap "gui/$(id -u)" "$2" 2>/dev/null && return 0; sleep 2; done
  launchctl bootstrap "gui/$(id -u)" "$2"
}

command -v uv >/dev/null || { echo "uv is required: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2; exit 1; }
mkdir -p "$MLX_HOME/models"

if [[ $SKIP_VENV == 0 ]]; then
  step "Python 3.12 environment ($MLX_HOME/.venv)"
  [[ -x "$MLX_HOME/.venv/bin/python" ]] || uv venv --python 3.12 "$MLX_HOME/.venv"
  uv pip install --python "$MLX_HOME/.venv/bin/python" -r "$REPO/server/requirements.txt"
fi

step "Local mlx-vlm patches"
SITE=$("$MLX_HOME/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
PATCH="$REPO/server/patches/mlx-vlm-0.7.8-local.patch"
if patch -p1 -d "$SITE" -R --dry-run -s -f < "$PATCH" >/dev/null 2>&1; then
  echo "already applied"
else
  patch -p1 -d "$SITE" --forward < "$PATCH"
fi

step "Scripts ($MODE)"
place() {  # place <repo file> <destination>
  rm -f "$2"
  if [[ $MODE == link ]]; then ln -s "$1" "$2"; else cp "$1" "$2"; chmod +x "$2"; fi
}
place "$REPO/server/start-server.sh" "$MLX_HOME/start-server.sh"
place "$REPO/server/mlx-ctl" "$MLX_HOME/mlx-ctl"
place "$REPO/server/benchmark.sh" "$MLX_HOME/benchmark.sh"
ln -sf "$MLX_HOME/mlx-ctl" "$MLX_HOME/status.sh"   # older name, kept for compatibility
BIN_DIR="$(brew --prefix 2>/dev/null || echo /usr/local)/bin"
ln -sf "$MLX_HOME/mlx-ctl" "$BIN_DIR/mlx-ctl" && echo "mlx-ctl -> $BIN_DIR/mlx-ctl"

if [[ $SKIP_MODELS == 0 ]]; then
  step "Model weights (~30 GB)"
  export HF_XET_HIGH_PERFORMANCE=1
  "$MLX_HOME/.venv/bin/hf" download robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit \
    --local-dir "$MLX_HOME/models/Swift-1.5-Qwen3.8-27B-8bit"
  "$MLX_HOME/.venv/bin/hf" download robgaleano/Swift-1.5-Qwen3.8-27B-MTP-MLX-8bit \
    --local-dir "$MLX_HOME/models/Swift-1.5-Qwen3.8-27B-MTP-8bit"
fi

step "LaunchAgent (com.local.mlx-server)"
PLIST="$HOME/Library/LaunchAgents/com.local.mlx-server.plist"
mkdir -p "$(dirname "$PLIST")"
sed "s|__MLX_HOME__|$MLX_HOME|g" "$REPO/server/com.local.mlx-server.plist.template" > "$PLIST"
reload_agent com.local.mlx-server "$PLIST"
for _ in $(seq 1 45); do curl -sf http://127.0.0.1:8080/health >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:8080/health >/dev/null && echo "server is up on :8080" || echo "server not responding yet — check $MLX_HOME/server.log"

if [[ ! -f /etc/sudoers.d/mlx-iogpu ]]; then
  printf '\nOptional: run `mlx-ctl setup-memory-limit` once to let the GPU use all but 16 GiB of memory\n'
  printf '(reserves 16 GiB for macOS; needs your admin password). See docs/memory.md.\n'
fi
