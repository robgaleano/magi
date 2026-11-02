#!/usr/bin/env bash
# Claude Code status line: context meter for a local model.
#   green  < MAGI_CTX_WARN tokens (default 40K)  — full speed
#   yellow < MAGI_CTX_NEW tokens  (default 80K)  — slower, finish the current task
#   red    ≥ MAGI_CTX_NEW                        — /handoff, then /clear
# Claude Code pipes session JSON on stdin; see docs/clients.md ("Long sessions").
set -euo pipefail

WARN=${MAGI_CTX_WARN:-40000}
NEW=${MAGI_CTX_NEW:-80000}
# Claude Code compacts at window − 20K (output reserve) − 13K (buffer). Its status-line JSON
# reports 200K for unknown models even when CLAUDE_CODE_AUTO_COMPACT_WINDOW is set, so prefer the env.
COMPACT_RESERVE=33000

read -r used window effort cwd < <(jq -r '
  (.context_window // {}) as $c
  | ($c.current_usage // null) as $u
  | [ (if $u then ($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)
       else ($c.total_input_tokens // 0) end),
      ($c.context_window_size // 0),
      (.effort.level // "-"),
      ((.workspace.current_dir // .cwd // "") | split("/") | last) ]
  | @tsv')

k() { awk -v n="$1" 'BEGIN { printf (n >= 1000 ? "%.1fK" : "%d"), (n >= 1000 ? n / 1000 : n) }'; }

if (( used >= NEW )); then
  color=31; hint=" · /handoff then /clear"
elif (( used >= WARN )); then
  color=33; hint=" · finish this task"
else
  color=32; hint=""
fi

window=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-$window}}
limit=""
(( window > COMPACT_RESERVE )) && limit="/$(k $(( window - COMPACT_RESERVE )))"
printf '\033[%sm● %s%s\033[0m%s \033[2m· %s · effort %s\033[0m' \
  "$color" "$(k "$used")" "$limit" "$hint" "${cwd:-?}" "$effort"
