# Troubleshooting

Problems hit while building MAGI, and what fixed them.

### Clients get HTTP 401 "Invalid API key"
The server requires the key from `~/.config/magi/api-key`. Check the client's setting ([clients.md](clients.md#api-key)) and restart the client (Hermes: `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`). HTTP 403 instead means the request came from a non-Tailscale network address.

### Server holds 80+ GiB while idle
After long requests with the MTP drafter, `mlx-vlm 0.7.8` kept the finished speculative batch alive until the next request arrived. Fixed by the [local patch](setup.md#local-mlx-vlm-patch). If it comes back after an `mlx-vlm` upgrade, re-apply the patch. Don't shrink the prompt cache to "fix" memory before ruling out a leak — `mlx-ctl status` shows how much is cache.

### Killing the server doesn't stop it
`KeepAlive` in the LaunchAgent restarts it instantly, and starting `start-server.sh` by hand next to it gives two servers. Use `launchctl bootout` / `bootstrap` / `kickstart -k` ([setup.md](setup.md#the-launchd-service)).

### `KV_MODE=turboquant` fails on every request
`NotImplementedError: mixed key/value KV quantization schemes are not supported on the batch path`. The server can't mix 8-bit keys with TurboQuant values. Use `f16` (fastest here anyway — [benchmarks](benchmarks.md#kv-cache-precision)).

### tok/s looks far too low
Speeds from replies of a few tokens are meaningless. Benchmark with 500+ output tokens.

### Rebuilt menu bar app gets killed immediately (`Code Signature Invalid`)
Overwriting a signed binary in place leaves macOS with stale code-signing data for that file, and it kills the process with `SIGKILL`. Always delete first, then compile and sign — [`menubar/install.sh`](../menubar/install.sh) does this.

### Menu bar app not running after a rebuild
`launchctl kickstart -k` right after replacing the binary sometimes leaves it stopped. `install.sh` checks with `pgrep` and starts it again if needed.

### Two brain icons in the menu bar
A test copy was started by hand (`./mlx-menubar`) while the launchd copy was running. Quit one: `pgrep -fl mlx-menubar`, then `kill <pid>`.

### `cp: … are identical (not copied)` when updating `mlx-ctl`
`mlx-ctl` in Homebrew's `bin` is a symlink to `$MLX_HOME/mlx-ctl`, so editing the target updates it; copying onto it fails and breaks `&&` chains.

### `claude` command stops working after a VS Code update
It was a symlink into a versioned extension folder that the update deleted. Use [`clients/claude-code/claude-wrapper.sh`](../clients/claude-code/claude-wrapper.sh), which finds the newest version.

### Hermes plugin "not found" although it's installed
Hermes keeps two `uv` environments under `~/.hermes/installs/<id>/environments/<env>/venv/`, and the gateway may load a different one than the CLI. Install Python dependencies into both (or `hermes pm repair`) and restart Hermes.

### Hermes skills from `skills.sh` miss their `scripts/` and `references/`
The index install only fetched `SKILL.md` for some repos. Clone the skill repo and copy the whole skill folder into `~/.hermes/skills/<category>/<name>/`.

### Roo Code hangs on "API Request…"
Configure it as an OpenAI-compatible provider with context window `131072` and max output `16384` ([clients.md](clients.md#roo-code-vs-code)).

### macOS asks for Automation / network permission for `osascript`
Expected: the menu bar app's "Enable 112 GiB GPU limit…" and some Hermes skills (Apple Notes, iMessage) run `osascript`. Allow it once.

### Nothing reachable after a reboot
FileVault is waiting for the password at the machine; see [headless.md](headless.md#reboots-and-filevault).
