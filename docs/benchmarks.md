# Benchmarks

Test machine: **Mac Studio, M5 Max (18-core CPU, 40-core GPU, 614 GB/s memory bandwidth), 128 GB unified memory, macOS 27**. Temperature 0 unless noted. Decode speed scales mostly with memory bandwidth, so other chips will differ roughly in proportion.

## Swift-1.5 8-bit + MTP drafter (current setup, 2026-10-30)

| Test | Result |
| :--- | :--- |
| Short prompt, 512 tokens out, reasoning `off` | 48.3–49.6 tok/s |
| Short prompt, 1,024 tokens out, `xhigh` | 37.6 tok/s |
| Live speed while writing code (menu bar) | 47–48 tok/s |
| Live speed while writing prose | 28–32 tok/s |
| 86K-token prompt, first time | 104 s total; prompt cache 28.6 GiB afterwards |
| 140K-token prompt, first time | 279 s (prefill 538 tok/s), decode 15.0 tok/s |
| Same 140K prompt, new question | 6.4 s — 139,264 of 140,273 tokens from cache |
| Peak GPU memory, all tests | 73.7 GiB (GPU limit 112 GiB on 128 GB), 0 swap, macOS free memory never below 35% |

Decode speed depends on what is being written: code and structured text get more drafted tokens accepted than free prose. Speeds measured on replies of only a few tokens are meaningless.

## Speculative decoding block size

Measured earlier on `mlx-community/Qwen3.8-27B-8bit` + its MTP drafter (same architecture, before switching to Swift 1.5):

| Configuration | Decode | Speed-up | Accepted tokens / round |
| :--- | ---: | ---: | :--- |
| No drafter | 18.8 tok/s | 1.00× | 1.00 |
| MTP, block size 3 | 43.4 tok/s | 2.31× | 2.69 (84.7%) |
| **MTP, block size 4** (used) | **47.9 tok/s** | **2.55×** | 3.37 (79.3%) |
| MTP, block size 5 | 48.3 tok/s | 2.57× | 3.66 (66.9%) |

Block size 5 is barely faster and accepts far fewer drafts, so 4 is the default.

## Prompt cache: first vs repeated request

Also measured on `mlx-community/Qwen3.8-27B-8bit`:

| Prompt | First request | Repeated (cached) | Cached tokens |
| :--- | ---: | ---: | ---: |
| 12.0K tokens | 13.1 s | 2.35 s | 85% |
| 24.9K tokens | 29.2 s | 1.06 s | 98.7% |
| 49.8K tokens | 64.1 s | 2.11 s | 98.7% |

## KV cache precision

140K-token prompt, `mlx-vlm 0.7.8` server with the MTP drafter:

| `KV_MODE` | Short decode | 140K prefill | 140K decode | Peak GPU memory |
| :--- | ---: | ---: | ---: | ---: |
| **`f16`** (used) | 48–50 tok/s | **538 tok/s** | **15.0 tok/s** | **73.7 GiB** |
| `q8` | 49.5 tok/s | 384 tok/s | 10.3 tok/s | 92.3 GiB |
| 4-bit TurboQuant (keys and values) | 49.8 tok/s | 398 tok/s | 10.5 tok/s | 94.3 GiB |
| `turboquant` (8-bit keys, TurboQuant values) | fails on every request in the server | | | |

The last mode raises `NotImplementedError: mixed key/value KV quantization schemes are not supported on the batch path`. It does work in the `mlx_vlm.generate` CLI, which doesn't use the server's batch path.

## Reproducing

CLI comparison (no drafter vs drafter vs drafter + TurboQuant):

```bash
~/llm/mlx-qwen38/benchmark.sh
```

Against the running server — send a request and read the speed from the log:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit",
  "reasoning_effort": "off", "temperature": 0, "max_tokens": 512,
  "messages": [{"role": "user", "content": "Write a well-typed Python async HTTP client with retries and tests."}]
}' > /dev/null
grep "Decode completed" ~/llm/mlx-qwen38/server.log | tail -1
```

Live speed of a request in progress: `curl -s http://127.0.0.1:8080/v1/metrics | jq .live`.

Long-context test: build a ~140K-token prompt by repeating a sentence (`"Pack my box with five dozen liquor jugs now. " * 12750`), send it once, then again with a different question, and compare `Prefill completed` lines in `server.log`. Run `mlx-ctl clear-disk-cache` first for a cold start.
