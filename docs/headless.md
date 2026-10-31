# Headless operation

Running the server on a Mac with no monitor attached and using it from other devices (phone, tablet, laptop).

## Remote access

| Path | How |
| :--- | :--- |
| **Tailscale** | All devices on one tailnet. Nothing is port-forwarded on the router; the MAGI server answers only to localhost and Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and returns HTTP 403 to other LAN clients. |
| **SSH / Moshi** | macOS Remote Login is on. The [Moshi](https://getmoshi.app) iOS app connects over SSH/mosh, and `moshi-hook` (Homebrew service, `127.0.0.1:24543` only) forwards agent events and approval prompts as push notifications. |
| **Screen Sharing** | macOS Screen Sharing is on; connect with `vnc://<mac-tailscale-ip>`. A virtual-display app (e.g. BetterDisplay) keeps a normal resolution with no monitor attached. |
| **Telegram** | Akari's Hermes gateway runs a Telegram bot restricted to an allow-list of user IDs (`TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env`). Supports text, voice notes (transcribed locally) and slash commands such as `/status`, `/compress`, `/effort`, `/cron`. |
| **Hermes web UI** (optional, not enabled) | `hermes dashboard` serves on `127.0.0.1:9119`; `tailscale serve --bg --https 9443 http://127.0.0.1:9119` would expose it to the tailnet only. |

To use the model from another computer, point its clients at `http://<mac-tailscale-ip>:8080/v1`.

## Services

All are user LaunchAgents in `~/Library/LaunchAgents/`:

| Service | Starts | Restarts on crash |
| :--- | :--- | :--- |
| `com.local.mlx-server` | at login, without loading the model | yes |
| `com.local.mlx-menubar` | at login | no |
| `ai.hermes.gateway` (Akari) | at login | yes |
| `sh.brew.moshi-hook` | at login | yes |

Tailscale itself starts as a login item.

## Sleep

The Mac must not sleep, or every remote path disappears. Recommended:

```bash
sudo pmset -a sleep 0 disksleep 0 womp 1 autorestart 1
pmset -g custom   # verify
```

`autorestart 1` powers the Mac back on after a power cut. Without these settings it only stays awake while some app holds a "keep awake" assertion.

## Reboots and FileVault

The services above are user LaunchAgents, so they start only **after login**. With FileVault on, a rebooted Mac waits at the pre-boot unlock screen — nothing starts, not even Tailscale, until the password is typed at the machine, and auto-login can't be enabled.

- **Planned remote restart:** `sudo fdesetup authrestart` unlocks FileVault once and logs in, so everything comes back.
- **Power cut or crash:** needs the password typed locally. The only way around that is turning FileVault off and enabling auto-login, which leaves the disk unencrypted if the Mac is stolen.

After login the menu bar app re-applies the GPU memory limit as soon as the model loads.

## Memory pressure while unattended

Three things keep a long unattended session from exhausting memory:

1. The 16 GiB macOS reserve — [memory.md](memory.md#gpu-memory-limit-all-but-16-gib)
2. The 32 GiB cap on the in-RAM prompt cache, plus the idle-memory fix — [memory.md](memory.md#prompt-cache)
3. Akari's automatic compaction at 98K tokens — [clients.md](clients.md#automatic-compaction)

From Telegram, ask Akari to run `mlx-ctl status` or `mlx-ctl clear-cache`.
