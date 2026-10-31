#!/usr/bin/env bash
# Rebuilds mlx-vlm-<version>-local.patch by diffing the installed mlx-vlm against
# a pristine copy of the same version downloaded from PyPI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLX_HOME="${MLX_HOME:-$HOME/llm/mlx-qwen38}"
PY="$MLX_HOME/.venv/bin/python"
SITE=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
VERSION=$("$PY" -c 'import importlib.metadata as m; print(m.version("mlx-vlm"))')
OUT="$HERE/mlx-vlm-$VERSION-local.patch"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WHEEL_URL=$(curl -sL "https://pypi.org/pypi/mlx-vlm/$VERSION/json" |
  "$PY" -c 'import json, sys; print(next(u["url"] for u in json.load(sys.stdin)["urls"] if u["filename"].endswith(".whl")))')
curl -sL "$WHEEL_URL" -o "$TMP/mlx_vlm.whl"
(cd "$TMP" && unzip -q mlx_vlm.whl 'mlx_vlm/*')

: > "$OUT"
(cd "$TMP" && find mlx_vlm -name '*.py' | sort) | while read -r f; do
  if ! cmp -s "$TMP/$f" "$SITE/$f"; then
    diff -u --label "a/$f" --label "b/$f" "$TMP/$f" "$SITE/$f" >> "$OUT" || true
    echo "changed: $f"
  fi
done
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
