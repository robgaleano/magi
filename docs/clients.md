# Clients

Every client talks to the same server: `http://127.0.0.1:8080/v1` (OpenAI) or `http://127.0.0.1:8080` (Anthropic `/v1/messages`). From another device, use the Mac's Tailscale address instead of `127.0.0.1`; other LAN clients get HTTP 403.

The model ID can be `robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit`; the server maps it (and `claude-*`, `sonnet`, `opus`, `haiku`) to the loaded model.

## API key

Every client must send the server's key (`cat ~/.config/magi/api-key`) — see [security.md](security.md#api-key-enabled-by-default). Where each one takes it:

| Client | Setting |
| :--- | :--- |
| Akari (Hermes Agent) | `OPENAI_API_KEY=<key>` in `~/.hermes/.env` (used by the custom provider), then restart the gateway |
| Claude Code (CLI and VS Code extension) | `ANTHROPIC_AUTH_TOKEN` in `~/.claude/settings.json` and in VS Code's `claudeCode.environmentVariables` (sent as `Authorization: Bearer`; don't also set `ANTHROPIC_API_KEY`) |
| DeepSeek Harness | `LOCAL_MLX_API_KEY` in `~/.dsh/.credentials.yaml` |
| Roo Code | the API key field of the OpenAI-compatible provider |
| `mlx-ctl`, menu bar app | read `~/.config/magi/api-key` automatically |
| `curl` | `-H @<(printf 'Authorization: Bearer %s\n' "$(cat ~/.config/magi/api-key)")` |

## Reasoning level

| Client sends | Server uses |
| :--- | :--- |
| nothing | default from `mlx-ctl effort` / menu bar (`xhigh`) |
| `off` / `low` / `medium` / `xhigh` | as is |
| `high`, `max` | `xhigh` |
| `minimal` | `low` |

## Long sessions: context size and speed

Agents resend the whole conversation on every turn: system prompt, tool definitions, files read, command output, earlier replies. Two things follow from that:

- **Writing slows down as the context grows**, because every new token attends over all previous ones.
- **Reading the prompt stays cheap only while its beginning is unchanged.** The server's prompt cache reuses everything up to the first changed token; anything that rewrites earlier history (compaction, editing `CLAUDE.md` mid-session, switching models) makes it read the rest again.

Measured on the test machine:

| Context | Writing speed | Notes |
| :--- | ---: | :--- |
| Short prompt | 48–50 tok/s | reasoning `off`; 37.6 tok/s at `xhigh` |
| 60–98K | 15–25 tok/s | Akari's weekly cron job, `xhigh` |
| 140K | 15.0 tok/s | first read 279 s; a new question on the same prompt 6.4 s (cache) |

Compaction is not free either: the model first writes a summary at long-context speed, then the shortened conversation is read again from the first changed message. Starting a fresh session from a short notes file is usually faster.

### Zones

| Context | Zone | What to do |
| :--- | :--- | :--- |
| < 40K | green | full speed |
| 40–80K | yellow | finish the current task |
| ≥ 80K | red | `/handoff`, then `/clear` (or a new session) |
| ~98K | — | both clients compact automatically |

The Claude Code [status line](#status-line) and the [menu bar app](../menubar/README.md) show these zones. To change the 40K / 80K thresholds, set `MAGI_CTX_WARN` / `MAGI_CTX_NEW` in Claude Code's `env` and in the menu bar's LaunchAgent.

### Habits that keep sessions fast

1. **One task per session.** Fix, test, commit, then `/clear`.
2. **Keep state in files, not in the chat.** `/handoff` (Claude Code) writes `NOTES.md`; a new session reads it (~1–2K tokens) instead of carrying 80K of history.
3. **Keep `CLAUDE.md` / `AGENTS.md` short and don't edit them mid-session** — they sit at the start of every prompt.
4. **Search, don't dump.** `grep` and line ranges instead of whole files; `rtk` already trims Bash output.
5. **One long session at a time.** The 32 GiB prompt cache holds about one 86–140K session; two large sessions evict each other.
6. **Lower the reasoning level for routine edits.** `high`/`xhigh` produce many more tokens per reply.

The model itself can't tell when to start over (it doesn't see its own token count), so the warnings come from the tools.

## Akari (Hermes Agent)

<img src="../assets/akari.png" width="72" align="right" alt="Akari">

Akari is a [Hermes Agent](https://github.com/NousResearch/hermes-agent) running 24/7 as the launchd service `ai.hermes.gateway`, reachable from Telegram, the Hermes CLI and the desktop app. Relevant parts of `~/.hermes/config.yaml`: [`clients/hermes/config.example.yaml`](../clients/hermes/config.example.yaml).

- **Main model:** the local server, 131,072-token context.
- **Background tasks** (titles, session search, compression, web extraction, self-review) also run locally at `reasoning_effort: low`.
- **Plugins:**

  | Plugin | What it does |
  | :--- | :--- |
  | `rtk-rewrite` | Rewrites terminal commands through [`rtk`](https://www.rtk-ai.app/), cutting tool output by 60–90% before it enters the context |
  | `llmslim` | Compacts long conversations without an LLM call (below) |
  | `hermes-token-speed` | Shows decode tok/s in the desktop app |
  | `obsidian-memory` | Reads and writes an Obsidian vault |
  | `moshi-hooks` | Sends agent events and approval requests to the Moshi iOS app |

- **Tool deferral:** rarely used tools (browser, image generation, cron management, …) sit behind `tool_search`, so their schemas aren't sent with every request.

### Automatic compaction

Compaction is done by the client, not the server. `llmslim` (plugin defaults):

| Setting | Value |
| :--- | :--- |
| Triggers at | 75% of 131,072 = **98,304 tokens** (exact `prompt_tokens` from the server) |
| Compacts to | ~50% = **~65,536 tokens** |
| Never touches | system prompt + first 3 messages, last 6 messages, messages ≤ 200 tokens |

Because the start of the conversation stays byte-for-byte identical, the server's prompt cache keeps hitting after compaction. Verified on a synthetic 169K-token conversation (→ 64.5K) and in a real cron run (98,295 → 60,691 tokens). `/compress` in chat triggers it manually.

## Claude Code

[`clients/claude-code/settings.example.json`](../clients/claude-code/settings.example.json) → `~/.claude/settings.json`. It points every Claude model alias at the local server, replaces the model picker, sets the reasoning level to `high` (→ `xhigh`), runs `rtk` on Bash tool calls, and sets up the context handling below.

### Context window and auto-compact

Claude Code doesn't recognise the model, so by default it assumes a **200K** window and only compacts at ~167K, well past the slow zone. The example settings fix that:

| `env` | Value | Effect |
| :--- | :--- | :--- |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `131072` | real window (`/context` shows `131.1k`) |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `131072` | compacts at 131,072 − 20,000 (output reserve) − 13,000 (buffer) = **~98K**, the same point as Akari |

Check with `claude -p /context`: `Tokens: … / 131.1k` and `Autocompact buffer: 33k`. Measured on Claude Code 2.1.309–2.1.311.

Claude Code's compaction replaces the whole history with a summary, so only the system prompt and tools (~17K tokens) stay cached; the summary is read fresh.

### Status line

[`clients/claude-code/statusline.sh`](../clients/claude-code/statusline.sh) (`statusLine` in the example settings, needs `jq`):

```
● 62.0K/98.1K · finish this task · my-project · effort high
```

Context used / auto-compact point, coloured by [zone](#zones). Claude Code's status-line input still reports a 200K window for this model, so the script takes the window from `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.

### `/handoff`

[`clients/claude-code/commands/handoff.md`](../clients/claude-code/commands/handoff.md) → `~/.claude/commands/handoff.md` (a symlink keeps it updated):

```bash
mkdir -p ~/.claude/commands
ln -sf "$PWD/clients/claude-code/commands/handoff.md" ~/.claude/commands/handoff.md
```

`/handoff [focus]` writes or updates `NOTES.md` in the project root (goal, state, decisions, files, next steps, how to verify, open questions; under 800 words, no secrets). Then run `/clear` and say *"Read NOTES.md and continue with the next step."* Add `NOTES.md` to `.gitignore` if it shouldn't be committed.

Install the CLI with Homebrew: `brew install --cask claude-code` (→ `/opt/homebrew/bin/claude`). The VS Code extension bundles its own copy and reads the same `~/.claude/settings.json`.

Without Homebrew, [`clients/claude-code/claude-wrapper.sh`](../clients/claude-code/claude-wrapper.sh), installed as `~/.local/bin/claude`, runs the newest binary bundled with the VS Code extension (a plain symlink broke on every extension update).

`Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set · auth may not work as expected` at startup means both are set; remove `ANTHROPIC_API_KEY`. The server only checks the `Authorization: Bearer` header that `ANTHROPIC_AUTH_TOKEN` produces.

To go back to Anthropic's cloud: remove `~/.claude/settings.json`.

## DeepSeek Harness

[`clients/deepseek-harness/cordis.patch.yml`](../clients/deepseek-harness/cordis.patch.yml) → `~/.dsh/cordis.patch.yml`. Registers a `local-mlx` provider (131,072 context, 32,768 max output, reasoning levels off/low/medium/high) and makes it the default.

## Roo Code (VS Code)

Use an OpenAI-compatible provider with base URL `http://127.0.0.1:8080/v1`, the server's API key, the model ID above, context window `131072` and max output `16384`.
