#!/usr/bin/env bash
# Builds the MLX menu bar app, installs it into $MLX_HOME and starts it at every login.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_HOME="${MLX_HOME:-$HOME/llm/mlx-qwen38}"
BIN="$MLX_HOME/mlx-menubar"
LABEL="com.local.mlx-menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
mkdir -p "$MLX_HOME" "$(dirname "$PLIST")"

reload_agent() {  # reload_agent <label> <plist>: (re)load a LaunchAgent, waiting for the old one to unload
  local target="gui/$(id -u)/$1"
  if launchctl print "$target" >/dev/null 2>&1; then
    launchctl bootout "$target" 2>/dev/null || true
    for _ in $(seq 1 20); do launchctl print "$target" >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  for _ in 1 2 3; do launchctl bootstrap "gui/$(id -u)" "$2" 2>/dev/null && return 0; sleep 2; done
  launchctl bootstrap "gui/$(id -u)" "$2"
}

# Delete before compiling: overwriting a running, signed binary in place gets it
# killed by macOS with "Code Signature Invalid" (see docs/troubleshooting.md).
rm -f "$BIN"
swiftc -O "$REPO/menubar/mlx-menubar.swift" -o "$BIN"
codesign --force --sign - "$BIN"

sed "s|__MLX_HOME__|$MLX_HOME|g" "$REPO/menubar/$LABEL.plist.template" > "$PLIST"
reload_agent "$LABEL" "$PLIST"
sleep 2
pgrep -f "$BIN" >/dev/null || launchctl kickstart "gui/$(id -u)/$LABEL"
sleep 1
pgrep -f "$BIN" >/dev/null && echo "mlx-menubar is running (starts at login via $PLIST)" \
  || { echo "mlx-menubar did not start — see /tmp/mlx-menubar.err" >&2; exit 1; }
