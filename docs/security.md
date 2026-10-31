# Security

MAGI runs a model server on your Mac that other devices can reach. This page lists what protects it and what doesn't.

## API key (enabled by default)

`server/install.sh` creates a random key in `~/.config/magi/api-key` (permissions `0600`, never committed). When the file exists, `start-server.sh` exports it as `MLX_VLM_SERVER_API_KEY`, and the server rejects every request without `Authorization: Bearer <key>` with HTTP 401 — chat, Anthropic messages, `/health`, `/v1/metrics`, `/load`, `/unload`, cache reset, all of it.

`mlx-ctl` and the menu bar app read the same file and send the header for you (via a header file, so the key never shows up in `ps`). Each client needs the key once — see [clients.md](clients.md#api-key).

**Why it matters:** `mlx-vlm`'s server answers CORS preflights from any origin. Without a key, any web page open in a browser on the Mac can call `http://127.0.0.1:8080` — run prompts, read the replies, unload the model or wipe the cache. A page can't know the key, so with it those requests fail.

Rotate the key: write a new one (`openssl rand -hex 32 > ~/.config/magi/api-key`), restart the server, update the clients.

## Network access

The server listens on all interfaces so Tailscale devices can use it. Two layers limit who gets through:

1. **In the server** ([local patch](setup.md#local-mlx-vlm-patch)): only `127.0.0.1`/`::1` and Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) are served; other clients get HTTP 403. Caveat: `100.64.0.0/10` is shared carrier-grade NAT space, and some phone hotspots and ISPs hand out addresses from it — on such a network other devices would pass this check. The API key and the firewall below cover that case.

2. **Firewall** — [`server/hardening/lan-lockdown.sh`](../server/hardening/lan-lockdown.sh) adds macOS `pf` rules that drop incoming SSH (22), Screen Sharing (5900), the MAGI server (8080) and mosh (UDP 60000–61000) on every physical interface (Ethernet, Wi-Fi, Thunderbolt). Tailscale (`utun*`) and localhost aren't affected. A LaunchDaemon re-applies the rules at boot.

   ```bash
   sudo ./server/hardening/lan-lockdown.sh install                  # firewall rules
   sudo ./server/hardening/lan-lockdown.sh install --ssh-keys-only  # + SSH key login only
   sudo ./server/hardening/lan-lockdown.sh status
   sudo ./server/hardening/lan-lockdown.sh uninstall
   ```

   `uninstall` removes the rules, the boot job **and** the key-only SSH setting, but leaves pf itself enabled. If Private Relay still reports "incompatible" afterwards, `sudo pfctl -d` turns pf off (macOS default).

   After this, SSH and Screen Sharing work over Tailscale only — not from the same Wi-Fi by local IP. Side effect: macOS turns off **iCloud Private Relay** ("Software installed on this Mac is incompatible with Private Relay") while pf is enabled; Safari still works, just without Private Relay. `--ssh-keys-only` refuses to run if `~/.ssh/authorized_keys` is empty, so you can't lock yourself out.

   The macOS Application Firewall (System Settings → Network → Firewall) is a different tool: it allows or blocks *apps*, not networks, so it can't express "Tailscale yes, Wi-Fi no".

## Passwordless sudo

`mlx-ctl setup-memory-limit` adds `/etc/sudoers.d/mlx-iogpu`, which allows exactly two commands without a password — setting `iogpu.wired_limit_mb` to the GPU limit or back to `0`. sudoers matches the full command line, so it can't be used to run anything else or set other values.

## Secrets that never belong in this repo

Keep these out of commits (all live outside the repo by design):

| Secret | Where it lives |
| :--- | :--- |
| MAGI server API key | `~/.config/magi/api-key` |
| Hermes keys, Telegram bot token, allowed user IDs | `~/.hermes/.env` |
| Claude Code / DeepSeek Harness keys | `~/.claude/settings.json`, `~/.dsh/.credentials.yaml` |
| Hugging Face token | `~/.cache/huggingface/token` (`hf auth login`) |
| Tailscale addresses and machine names | not needed anywhere in the repo |

The example configs in [`clients/`](../clients) use placeholders. GitHub secret scanning and push protection are enabled on the repository.

## Not covered

- Anyone with access to your Tailscale network or your logged-in Mac account can use the server (with the key on disk) — protect those accounts.
- The model can run tools through agents such as Hermes or Claude Code; their own permission settings decide what it may do on your machine.
- FileVault, a strong login password and automatic macOS updates are assumed.
