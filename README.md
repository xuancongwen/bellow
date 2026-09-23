# BellowFlow

A native macOS menu-bar app wrapping VoxType, bundled Whisper, a private Ollama
server, and Sam Wen's original cleanup Modelfile. MIT-licensed application code.
Apple Silicon, macOS 13 or newer. Formerly known as VoxBundle.

**Status: initial implementation, not a verified shipping Mac application.**
The source and release builder were produced on Linux. The macOS GUI, Swift
compilation, permission attribution, Metal inference, packaging, and end-to-end
speech insertion still need the Mac acceptance pass below. No prebuilt DMG is
included in this source archive. This distinction matters: the packaging is
intended to give end users an out-of-the-box app, but that has not been proven yet.

## Intended end-user experience

1. Install the built app into `/Applications` and open it.
2. Grant Microphone and Accessibility access through the setup window.
3. Click Start. The app checks RAM, prepares its bundled model store, and loads
   both engines before reporting Ready.
4. Press **Control + Option + Space**, speak, and press it again to finish.
5. A nonactivating overlay shows listening, transcription, and cleanup. The
   resulting English text is typed into the currently focused application.
6. Quit from the menu bar to release the engines and model memory.

No runtime Homebrew, Python, Rust, Hammerspoon, external Ollama installation,
account, API key, or model download is needed once the full bundle is built.
A signed, notarized release is required for normal Gatekeeper distribution.
macOS permissions still require user approval; they cannot be preapproved.
This edition has toggle recording, not hold-to-talk. Do not switch text targets
while dictating: insertion uses VoxType's current-focus behavior.

## Models and memory

- Whisper **large-v3-turbo Q5_0**, approximately 574 MB of model weights,
  English forced, translation disabled, Metal and whisper.cpp flash attention
  enabled.
- **Qwen 2.5 7B** from `qwen2.5:7b`, imported with the exact Modelfile from
  `https://github.com/xuancongwen/voxtype-llm-wrapper` at commit
  `27feaad731a3d9492dd1f31bb3d19a79cfc523ad`.
- Temperature **0**, context **4096**. The repository's system prompt and
  examples are unchanged. The request caps generated output at 2048 tokens;
  truncated, malformed, failed, or empty results fall back to the raw transcript.
- Ollama has `keep_alive=-1` on warmup and every cleanup request, plus
  `OLLAMA_KEEP_ALIVE=-1`. Whisper explicitly disables on-demand loading and
  unloading. Both engines are owned by the app and remain loaded until quit.
- One loaded cleanup model, one parallel request, Flash Attention, and Q8 KV
  cache reduce avoidable memory use. These do not change the model's weights.
  Startup blob pruning is disabled (`OLLAMA_NOPRUNE`) so the private store is
  never modified by the server.
- The current full bundle refuses Macs with less than **16 GB RAM**. It also
  requires approximately **9 GiB of reclaimable memory** before startup:
  a conservative 7 GiB working-set allowance plus 2 GiB reserve.
- **24 GB+ recommended; 64 GB has ample headroom.** A 16 GB Mac must have enough
  memory available at launch. This is an admission policy, not an enforceable
  memory cap. Measured on an M1 Max (see `docs/memory-profile.md`): Ollama
  needs **5.1 GiB** for Qwen (4.1 GiB weights, file-backed via mmap, plus KV and
  compute buffers), Whisper holds **0.64 GB** resident and peaks at **0.86 GB**,
  for a combined working set of about **5.4 GB resident / 5.7 GB peak**. The
  7 GiB allowance therefore keeps roughly 1.3 GiB of margin.
- Memory-pressure warning/critical events pause new recordings. Finishing or
  cancelling an active recording remains available. Models are not silently
  unloaded. Close other apps or quit BellowFlow; recording resumes when pressure
  clears.
- An **8 GB edition is not implemented**. It should use a smaller explicitly
  selected cleanup model with the same editing prompt, then get its own quality
  and memory tests. The app does not silently substitute a smaller model.

macOS can compress or page memory regardless of `keep_alive`. The app retains
loaded models, but cannot guarantee physical RAM residency or zero latency under
system pressure. No memory is locked with `mlock`.

The installer includes all model weights. First launch copies the Ollama store
into Application Support without modifying the signed app bundle. Allow roughly
**12–15 GB free disk** for installed resources plus the writable copy; the build
machine needs substantially more for Rust artifacts and download caches.

## Build a full app on a Mac

Build prerequisites only (end users do not need these): Xcode Command Line Tools,
Swift 5.9+, Rust/Cargo, CMake, Git, Python 3.11+, and internet access. The
builder fetches cargo git dependencies with the git CLI (so SSH agents and
`url.<base>.insteadOf` rewrites work) and links clang's compiler-rt into
VoxType, which whisper.cpp's Objective-C Metal backend needs on current Xcode.

```sh
xcode-select --install
# If using Homebrew for developer tools:
brew install rust cmake python
./scripts/build-macos.sh
```

The builder compiles pinned VoxType with Metal, compiles the two native Swift
executables, verifies downloaded runtime/model hashes, thins the universal
Ollama binary to arm64 and drops its x86_64-only CPU backends, imports the
original Modelfile, copies only referenced Ollama model blobs, audits linked
libraries, signs nested code, verifies the signature, and creates:

```
dist/BellowFlow-macOS-arm64.dmg
```

The initial download includes several GB of weights. There is no runtime model
fetch. The build's Ollama server uses port 11439; quit a running BellowFlow before
building. The `qwen2.5:7b` registry tag is resolved at build time and may change;
`models/inventory.json` records and verifies the exact content hashes included
in that build. Freeze the manifest digest when preparing a public release.

For a distributable signed/notarized release, provide an Apple Developer ID
Application identity and an existing notarytool keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notary-profile' ./scripts/build-macos.sh
```

Without those credentials the script makes an ad-hoc signed development build.
Rebuilding an ad-hoc executable can invalidate previous permission grants. Do not
ship it as a frictionless public installer. No Apple signing credentials or
GitHub publishing actions are included or assumed.

`.github/workflows/macos.yml` builds Swift and runs tests on pushes/PRs. Its
manual `bundle` option attempts the full build and retains the DMG as an artifact;
it does not publish a release. It must be run in a GitHub repository before
claiming CI success. Full bundle jobs download large models and can be slow.

## Architecture and configuration

The AppKit/SwiftUI shell owns a private VoxType process and a bundled Ollama
process. Ollama listens only on `127.0.0.1:11439`; an existing listener causes
startup to fail rather than attach to another user's service. VoxType uses a
private runtime directory, separate from a standalone VoxType installation.
The global shortcut uses Carbon registration, so this shell does not need an
Input Monitoring event tap. Native NSPanel UI never takes keyboard focus.

VoxType pipes text over stdin to the compiled `VoxClean` helper. That helper
calls the private local Ollama API and writes only the resulting transcript to
stdout. Text is never interpolated into a shell command. The original Modelfile
is bundled verbatim. Changing it requires rebuilding the model and bundle; it
is not dynamically reparsed on every dictation.

Configuration and diagnostic log live in:

```
~/Library/Application Support/BellowFlow/
```

`config.toml` is created on first startup and preserved after that. Use the setup
window's “Open configuration and diagnostic log” button, then quit and restart
to apply manual changes. Model paths point through stable links refreshed at
launch. This app does not overwrite your existing `~/.config/voxtype` config;
VoxType is started with `--config`, which replaces rather than merges it.
Do not enable a second built-in VoxType hotkey/OSD in this managed configuration.

The generated VoxType defaults, each verified against the pinned source:

| Section | Setting | Why |
| --- | --- | --- |
| top level | `engine = "whisper"`, `state_file = "auto"` | Explicit engine; state file under the private runtime directory the app watches. |
| `[hotkey]` | `enabled = false` | BellowFlow registers ⌃⌥Space itself; VoxType's own hotkey would need Input Monitoring. |
| `[osd]` | `enabled = false` | BellowFlow draws its own overlay. |
| `[audio]` | `device = "default"`, `sample_rate = 16000`, `max_duration_secs = 120` | Safety cap; a recording is transcribed automatically at the limit. |
| `[whisper]` | `mode = "local"`, absolute model path, `language = "en"`, `translate = false`, `flash_attention = true` | Bundled model only, English forced, whisper.cpp flash attention on Metal. |
| `[whisper]` | `on_demand_loading = false`, `gpu_isolation = false`, `max_loaded_models = 1`, `cold_model_timeout_secs = 0` | Whisper stays loaded until quit and is never evicted. |
| `[output]` | `mode = "type"`, `fallback_to_clipboard = true`, `auto_submit = false` | CGEvent typing, then AppleScript, then clipboard; never a stray Enter. |
| `[output.notification]` | all `false` | Upstream's default posts a transcript preview as a macOS notification through `osascript`; this bundle keeps dictation private. |
| `[output.post_process]` | `command = "exec '<VoxClean>'"`, `timeout_ms = 60000`, `trim = true`, `fallback_on_empty = true` | Text is piped over stdin; VoxClean's own 56 s timeout expires first so the raw transcript still lands. |

Everything else keeps the pinned VoxType default (for example filler-word
filtering on, VAD off, no audio feedback). The private Ollama server receives
`OLLAMA_HOST=127.0.0.1:11439`, `OLLAMA_MODELS=<Application Support>/models-v1`,
`OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`,
`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, and `OLLAMA_NOPRUNE=1`;
all are recognised by the pinned `v0.11.10`. `tests/test_config_template.py`
parses the template and pins these invariants, because VoxType silently ignores
unknown keys.

Info/debug transcript logging in VoxType is suppressed. Engine diagnostics go
to an owner-only log reset on launch. Ollama may create its standard local
identity file in `~/.ollama`; model blobs and the server are isolated. There is
no cloud transcription, telemetry, or app-managed transcript history.

## Validation performed here

- Model exporter tests: shared-blob deduplication, excluding unrelated models,
  rejection of corrupt blobs, rejection of invalid/path-traversal digests.
- Config template test: the generated `config.toml` parses and keeps the
  managed defaults listed above.
- Shell syntax and Python compilation checks.
- Original Modelfile and VoxType license compared byte-for-byte with upstream.
- Upstream config/IPC/model-residency integration checked against pinned source.

Verified on an Apple Silicon Mac (macOS 26, Swift 6.4 toolchain): both Swift
executables compile, all nine Python tests pass with zero skips (including
`tests/test_cleanup.py`, which exercises the real compiled helper against a
local HTTP mock), and the pinned Ollama and Whisper download hashes match. The
full bundle build, permissions, and end-to-end dictation are still the
acceptance pass below.

## Required Mac acceptance pass before calling this release-ready

1. Compile both Swift executables; run all nine Python tests with zero skips.
2. Build the complete bundle, check `otool` audit and strict signature validation.
3. On a clean account, launch from `/Applications`; verify Microphone and
   Accessibility attribution. If macOS attributes Accessibility to the nested
   VoxType helper, grant the actual helper and record the required UX fix before
   public release. Do not assume granting the parent is enough.
4. Disable internet after installation; confirm first launch and dictation work.
5. Test recording/cancel, terminal and browser text fields, Unicode, app focus,
   screen changes, sleep/wake, and repeated launch/quit.
6. Test the Modelfile examples, including questions, commands, profanity,
   self-corrections, and prompt-injection-like dictated text. Prompt rules are
   not a correctness guarantee; benchmark actual outputs.
7. Confirm both models remain loaded after a long idle period. Measure latency,
   memory pressure, swap, and combined process-tree memory on 16/24 GB Macs
   (64 GB is done: `docs/memory-profile.md`).
8. Force model-load/engine failures and cleanup timeouts; verify useful status,
   raw-transcript fallback, and no surviving inference processes after quit.
9. Test normal Developer ID signing, notarization, Gatekeeper, and permission
   persistence across an update. Complete third-party license/dependency review
   before public distribution.

## License and provenance

Application source: MIT. VoxType and Ollama: MIT. Whisper: MIT. Qwen 2.5 7B:
Apache 2.0. The build includes primary upstream/model licenses. The user's
Modelfile is copied by explicit request; its repository currently has no separate
license file, so settle its redistribution license before public distribution.
Full transitive dependency notices remain a release-review item.

Pinned VoxType: `320a737e5d3c8662e0ec7de95f75407baa784d82`.
Pinned Ollama: `v0.11.10`, archive SHA-256 verified by the builder.
Whisper Q5 weights: SHA-256 verified by the builder.
