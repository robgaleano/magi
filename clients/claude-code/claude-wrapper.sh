#!/bin/sh
# Runs the Claude Code binary bundled with the newest installed VS Code extension.
# (A plain symlink broke whenever VS Code updated the extension to a new versioned folder.)
BIN=$(ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-*-darwin-arm64/resources/native-binary/claude 2>/dev/null | sort -V | tail -n 1)
[ -n "$BIN" ] || { echo "claude: Claude Code VS Code extension not found in ~/.vscode/extensions" >&2; exit 1; }
exec "$BIN" "$@"
