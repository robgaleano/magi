# Setup

## Requirements

- Apple Silicon Mac with enough unified memory: the 8-bit model needs ~28 GiB plus room for context, so 64 GB is the practical minimum and 128 GB is comfortable. Tested on: Mac Studio, M5 Max (18-core CPU, 40-core GPU, 614 GB/s memory bandwidth), 128 GB unified memory, macOS 27.
- [`uv`](https://docs.astral.sh/uv/): `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Xcode Command Line Tools (for the menu bar app): `xcode-select --install`
- ~35 GB of free disk for the weights, plus up to 40 GB for the on-disk prompt cache.

## Install

```bash
git clone https://github.com/robgaleano/magi.git ~/llm/magi
cd ~/llm/magi
./server/install.sh
```

`server/install.sh` does, in order:

1. Creates a Python 3.12 environment in `$MLX_HOME/.venv` (default `MLX_HOME=~/llm/mlx-qwen38`) and installs the exact package versions from [`server/requirements.txt`](../server/requirements.txt) (`mlx 0.32.4`, `mlx-vlm 0.7.8`, …).
2. Applies [`server/patches/mlx-vlm-0.7.8-local.patch`](../server/patches/mlx-vlm-0.7.8-local.patch) (see [below](#local-mlx-vlm-patch)). Skipped if already applied.
3. Copies `start-server.sh`, `mlx-ctl` and `benchmark.sh` into `$MLX_HOME` and links `mlx-ctl` into Homebrew's `bin`.
4. Downloads both models from Hugging Face into `$MLX_HOME/models/`.
5. Creates the server API key in `~/.config/magi/api-key` if it doesn't exist ([security.md](security.md)).
6. Installs and starts the launchd service `com.local.mlx-server`.

Options: `--link` symlinks the scripts to the repo instead of copying them, so edits are tracked by git; `--skip-models`; `--skip-venv`.

Then, once:

```bash
mlx-ctl setup-memory-limit   # passwordless rule so the GPU can use all but 16 GiB (see memory.md)
./menubar/install.sh         # optional menu bar app
sudo ./server/hardening/lan-lockdown.sh install   # recommended: Tailscale/localhost-only access (security.md)
```

Then give each client the API key — [clients.md](clients.md#api-key).

## Daily use: `mlx-ctl`

| Command | What it does |
| :--- | :--- |
| `mlx-ctl status` | Server state, loaded model, GPU memory, prompt cache, last speeds, memory split |
| `mlx-ctl mount` / `unmount` | Load the model (~28 GiB) or free it completely; also sets/resets the GPU limit |
| `mlx-ctl clear-cache` | Free the in-RAM prompt cache; the model stays loaded, chat history is unaffected |
| `mlx-ctl clear-disk-cache` | Also clear the on-disk prompt cache (`~/.cache/mlx-vlm/apc/`) |
| `mlx-ctl effort <off\|low\|medium\|xhigh>` | Default reasoning level for requests that don't set one |
| `mlx-ctl setup-memory-limit` | One-time sudoers rule for the GPU memory limit |

The model also loads automatically on the first request.

## The launchd service

The server runs as `~/Library/LaunchAgents/com.local.mlx-server.plist` (template: [`server/com.local.mlx-server.plist.template`](../server/com.local.mlx-server.plist.template)) with `RunAtLoad` and `KeepAlive`. It starts **without** loading the model (`PRELOAD=0`).

```bash
launchctl kickstart -k gui/$(id -u)/com.local.mlx-server && sleep 5 && mlx-ctl mount   # restart
launchctl bootout gui/$(id -u)/com.local.mlx-server                                    # stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.mlx-server.plist     # start
tail -f ~/llm/mlx-qwen38/server.log                                                    # logs
```

Killing the Python process doesn't stop it; `KeepAlive` restarts it immediately.

## Server settings (`start-server.sh`)

| Variable | Value | Why |
| :--- | :--- | :--- |
| `DRAFT_BLOCK_SIZE` | `4` | Best speed with the MTP drafter (≈2.5× vs no drafter) |
| `MAX_TOKENS` | `32768` | Max output per reply |
| `PREFILL_STEP` | `4096` | Prompt processed in 4K-token chunks |
| `KV_MODE` | `f16` | Compressed KV was slower and used more memory — [benchmarks](benchmarks.md#kv-cache-precision) |
| `APC_MEMORY_MAX_GB` / `APC_DISK_MAX_GB` | `32` / `40` | Prompt cache in RAM / on SSD — [memory.md](memory.md#prompt-cache) |
| `APC_NUM_BLOCKS`, `APC_CHECKPOINT_ENTRIES`, `APC_CHECKPOINT_INTERVAL_TOKENS` | `16384`, `24`, `4096` | Prompt cache granularity |
| `MLX_VLM_DEFAULT_REASONING_EFFORT` | `xhigh` (set in the LaunchAgent) | Default thinking level |

To try a different value without editing files: `launchctl setenv KV_MODE q8`, restart, and undo with `launchctl unsetenv KV_MODE`.

## Local mlx-vlm patch

[`server/patches/mlx-vlm-0.7.8-local.patch`](../server/patches/mlx-vlm-0.7.8-local.patch) changes 8 files of `mlx-vlm 0.7.8`:

| File | Change |
| :--- | :--- |
| `generate/ar.py` | Idle-memory fix: the speculative batch frees its KV cache and hidden states when the last request finishes |
| `server/generation.py` | Idle-memory fix (closes the batch generator as soon as the server is idle); model-unload cleanup; live decode tok/s tracker |
| `server/app.py` | GPU memory limit on load/unload (`MLX_IOGPU_WIRED_LIMIT_MB`); `/load` endpoint and full memory release on `/unload`; `/v1/reasoning-effort`; `"live"` block in `/v1/metrics`; only localhost and Tailscale clients allowed (others get HTTP 403) |
| `server/anthropic.py` | Maps `claude-*`, `sonnet`, `opus`, `haiku` model IDs to the loaded model so Claude Code never triggers a model swap |
| `server/request_normalization.py` | Default reasoning level from `MLX_VLM_DEFAULT_REASONING_EFFORT`; `high`/`max` → `xhigh`, `minimal` → `low` |
| `server/schemas.py` | Accepts a `reasoning_effort` request field |
| `convert.py`, `speculative/drafters/mtp_split.py` | Copied files get `0644` permissions (needed for the Hugging Face upload) |

### Upgrading mlx-vlm

Upgrading replaces the patched files. After an upgrade, check whether the new version already covers each change, then:

```bash
SITE=$(~/llm/mlx-qwen38/.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
patch -p1 -d "$SITE" --dry-run < server/patches/mlx-vlm-0.7.8-local.patch   # check first
patch -p1 -d "$SITE" < server/patches/mlx-vlm-0.7.8-local.patch
```

If the dry run fails, the upstream code moved and the hunks have to be re-applied by hand.

### Regenerating the patch

After editing files inside the venv, rebuild the patch from a pristine copy of the installed version:

```bash
./server/patches/make-patch.sh
```

## Converting the model yourself

[`server/quantize/convert-swift15.sh`](../server/quantize/convert-swift15.sh) downloads UkisAI's BF16 weights and converts them to 8-bit MLX plus a separate 8-bit MTP drafter; [`verify-and-upload-swift15.sh`](../server/quantize/verify-and-upload-swift15.sh) checks tensor counts and uploads both to Hugging Face. You only need these to rebuild or re-publish the weights — `install.sh` downloads the published ones.
