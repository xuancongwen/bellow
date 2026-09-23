# Memory profile

Measured 2026-09-23 on an Apple M1 Max, 64 GB, macOS 26.6, with the exact
binaries and settings the bundle ships: the pinned Ollama `v0.11.10` (arm64
slice) with `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`,
`OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=-1`;
the `voxtype-llm-wrapper` model created from `Resources/Modelfile` on the
`qwen2.5:7b` tag (4.7 GB Q4_K_M blob); and VoxType `320a737` built with
`--features gpu-metal` running the app-generated `config.toml`
(`flash_attention = true`, `on_demand_loading = false`).

"Footprint" is `footprint(1)` phys_footprint, which counts dirty and wired
memory. File-backed mmapped pages are reported separately because macOS can
evict them under pressure and re-fault them from disk.

## Ollama + Qwen 2.5 7B (cleanup model)

| State | Footprint (dirty) | Notes |
| --- | --- | --- |
| Server idle, no model | 11 MB | |
| Model loaded, idle | server 77 MB + runner 205 MB | runner RSS 4,688 MB: 4,168 MiB weights Metal-mapped + 292 MiB CPU-mapped, all file-backed via mmap |
| Cleanup request, 75 words | peak 304 MB | 3.7 s wall through the compiled `VoxClean` helper |
| Cleanup request, 300 words | peak 305 MB | 3.9 s wall |
| 10 s after requests | 304 MB | stays resident, as intended |
| After quit | 0 processes | |

Ollama's own scheduler accounting for this configuration: **5.1 GiB required**
= weights 4.1 GiB + KV cache 119 MiB (q8_0, 4096 cells, 28 layers) + Metal
compute buffer 304 MiB + CPU compute buffer 15 MiB. All 29/29 layers offload
to Metal. First load from a cold disk cache took 22.9 s; the app allows 180 s.

## VoxType + Whisper large-v3-turbo Q5_0

| State | Footprint | Notes |
| --- | --- | --- |
| Daemon idle, model loaded | 636 MB (RSS 661 MB) | whisper.cpp copies the 573 MB model into Metal buffers, so this is dirty memory, not file cache |
| One-shot transcribe, 19 s clip | peak 804 MB | 10.9 s wall including first-run Metal shader compilation |
| One-shot transcribe, 78 s clip | peak 855 MB | 2.6 s wall once shaders are cached |

Transcripts of the synthetic clips were word-accurate.

## Combined working set

| Component | Resident | Peak during dictation |
| --- | --- | --- |
| Qwen weights (file-backed, mmapped) | 4.4 GB | 4.4 GB |
| Ollama server + runner (dirty) | 0.28 GB | 0.31 GB |
| VoxType + Whisper (dirty) | 0.64 GB | 0.86 GB |
| BellowFlow shell + VoxClean (estimated, not measured) | < 0.1 GB | < 0.1 GB |
| **Total** | **≈ 5.4 GB** | **≈ 5.7 GB** |

`MemoryBudget.swift` admits a launch only with 7 GiB (working set) + 2 GiB
(reserve) reclaimable. The measured peak is about 5.7 GB, so the 7 GiB
allowance keeps roughly 1.3 GiB of margin for longer contexts and Metal
overhead; the constants were left unchanged.

## Minimum system requirements

- **16 GB unified memory is the floor.** The models need ~5.7 GB at peak while
  macOS itself commonly holds 5–8 GB, and Metal caps a process's recommended
  working set at roughly 80 % of RAM. On an 8 GB Mac the 5.1 GiB cleanup model
  alone would consume most of the GPU budget and the rest would swap; the
  README's "8 GB edition" would need a smaller cleanup model.
- **24 GB recommended** for running the bundle alongside a browser and an IDE
  without memory-pressure pauses.
- **Disk:** about 5.3 GB of model weights in the app plus a 4.7 GB writable
  copy of the Ollama store on first launch; the README's 12–15 GB guidance
  stands.
- Apple Silicon required (Metal). Latency will be higher on base M-series chips
  than the M1 Max numbers above; memory use is the same because the model
  files are identical.

Not yet measured: a 16 GB or 24 GB Mac under real memory pressure (acceptance
item 7), and the BellowFlow GUI process itself.

## Reproducing

```sh
# Ollama: serve with the app environment, warm, then pipe text through VoxClean
OLLAMA_HOST=127.0.0.1:11439 OLLAMA_MODELS=.cache/models OLLAMA_KEEP_ALIVE=-1 OLLAMA_NUM_PARALLEL=1 \
OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NOPRUNE=1 ollama serve &
curl -s http://127.0.0.1:11439/api/generate -d '{"model":"voxtype-llm-wrapper","prompt":"","keep_alive":-1}'
footprint -p <server pid>; footprint -p <runner pid>
echo "um so hey john does tuesday work" | BELLOWFLOW_OLLAMA=http://127.0.0.1:11439 .build/release/VoxClean

# Whisper: peak of a one-shot transcription, then the daemon's resident cost
/usr/bin/time -l voxtype --config config.toml transcribe clip-16k-mono.wav
XDG_RUNTIME_DIR=/tmp/vb voxtype --config config.toml daemon & footprint -p $!
```
