# Clients

Every client talks to the same server: `http://127.0.0.1:8080/v1` (OpenAI) or `http://127.0.0.1:8080` (Anthropic `/v1/messages`). From another device, use the Mac's Tailscale address instead of `127.0.0.1`; other LAN clients get HTTP 403.

The model ID can be `robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit`; the server maps it (and `claude-*`, `sonnet`, `opus`, `haiku`) to the loaded model.

## API key

Every client must send the server's key (`cat ~/.config/magi/api-key`) — see [security.md](security.md#api-key-enabled-by-default). Where each one takes it:

| Client | Setting |
| :--- | :--- |
| Akari (Hermes Agent) | `OPENAI_API_KEY=<key>` in `~/.hermes/.env` (used by the custom provider), then restart the gateway |
| Claude Code (CLI and VS Code extension) | `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` in `~/.claude/settings.json` and in VS Code's `claudeCode.environmentVariables` |
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

Because the start of the conversation stays byte-for-byte identical, the server's prompt cache keeps hitting after compaction. Verified on a synthetic 169K-token conversation (→ 64.5K). `/compress` in chat triggers it manually.

## Claude Code

[`clients/claude-code/settings.example.json`](../clients/claude-code/settings.example.json) → `~/.claude/settings.json`. It points every Claude model alias at the local server, replaces the model picker, sets the reasoning level to `high` (→ `xhigh`), and runs `rtk` on Bash tool calls.

The `claude` CLI ships inside the VS Code extension. [`clients/claude-code/claude-wrapper.sh`](../clients/claude-code/claude-wrapper.sh), installed as `~/.local/bin/claude`, always runs the newest installed version (a plain symlink broke on every extension update).

To go back to Anthropic's cloud: remove `~/.claude/settings.json`.

## DeepSeek Harness

[`clients/deepseek-harness/cordis.patch.yml`](../clients/deepseek-harness/cordis.patch.yml) → `~/.dsh/cordis.patch.yml`. Registers a `local-mlx` provider (131,072 context, 32,768 max output, reasoning levels off/low/medium/high) and makes it the default.

## Roo Code (VS Code)

Use an OpenAI-compatible provider with base URL `http://127.0.0.1:8080/v1`, the server's API key, the model ID above, context window `131072` and max output `16384`.
