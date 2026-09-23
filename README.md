# BellowFlow

A native macOS menu-bar dictation app. Press **Control + Option + Space**, speak,
press it again, and the cleaned-up English text is typed into whatever app has
focus. Everything runs on your Mac: it bundles [VoxType](https://github.com/peteonrails/voxtype),
Whisper large-v3-turbo, a private [Ollama](https://github.com/ollama/ollama)
server, and Qwen 2.5 7B with Sam Wen's
[cleanup Modelfile](https://github.com/xuancongwen/voxtype-llm-wrapper).
MIT-licensed application code. Apple Silicon, macOS 13 or newer. Formerly
known as VoxBundle.

**Status: 1.0.0-rc.1 — builds, packages, and dictates end to end on an
Apple Silicon Mac; not yet Developer ID signed or notarized.** See
[Validation status](#validation-status) for exactly what has and has not been
checked.

## Install

Website: **<https://xuancongwen.github.io/bellowflow/>**

Open Terminal, paste this, and press Return:

```sh
curl -fsSL https://xuancongwen.github.io/bellowflow/install.sh | bash
```

It downloads the release (about 5 GB), verifies it, puts **BellowFlow** in
`/Applications`, and opens it. Then grant **Microphone** and **Accessibility**
in the setup window, click **Start**, wait for **Ready · ⌃⌥Space to dictate**,
and press ⌃⌥Space to talk. The script is
[`scripts/install.sh`](scripts/install.sh); `BELLOWFLOW_VERSION=v1.0.0-rc.1`
pins a release.

<details>
<summary>Install by hand instead</summary>

1. From the [releases page](https://github.com/xuancongwen/bellowflow/releases)
   download every `.dmg.part-*` file and the `.dmg.sha256` file. GitHub caps
   each release asset at 2 GB, so the DMG ships in parts.
2. Join and verify them:

   ```sh
   cd ~/Downloads
   cat BellowFlow-1.0.0-rc.1-macOS-arm64.dmg.part-* > BellowFlow-1.0.0-rc.1-macOS-arm64.dmg
   shasum -a 256 -c BellowFlow-1.0.0-rc.1-macOS-arm64.dmg.sha256
   ```

3. Open the DMG and drag **BellowFlow** to `/Applications`. Release candidates
   are ad-hoc signed, so the first launch needs **right-click → Open** (or
   `xattr -dr com.apple.quarantine /Applications/BellowFlow.app`).
4. Grant **Microphone** and **Accessibility** in the setup window and click
   **Start**. First start copies the bundled model store into Application
   Support (about 4.4 GB, once), then loads both engines. Later launches start
   automatically.

</details>

Dictate: press ⌃⌥Space, speak, press it again. A small overlay shows
listening, transcribing, and cleaning up. Do not switch windows while it is
typing. Quit from the menu bar to release the models.

No Homebrew, Python, Rust, Ollama installation, account, API key, network
access, or model download is needed at runtime. Recording is toggle, not
hold-to-talk; a recording is transcribed automatically at 120 seconds.

## System requirements

Measured with the shipped binaries and settings (`docs/memory-profile.md`):

| | |
| --- | --- |
| Chip | Apple Silicon (Metal). Intel is not supported. |
| macOS | 13 Ventura or newer |
| Memory | **16 GB minimum, 24 GB recommended.** Ollama needs 5.1 GiB for Qwen (4.1 GiB weights, file-backed, plus KV cache and compute buffers); Whisper holds 0.64 GB and peaks at 0.86 GB. Combined working set ≈ 5.4 GB resident, ≈ 5.7 GB during a dictation. |
| Disk | 12–15 GB: the app plus the writable copy of the model store |

The app refuses to load models on Macs with less than 16 GB, and requires about
9 GiB of reclaimable memory at start (a 7 GiB working-set allowance plus 2 GiB
reserve), which leaves roughly 1.3 GiB of margin over the measured peak. This
is an admission policy, not an enforceable cap: macOS can still compress or
page model memory under pressure, and nothing is `mlock`ed. Memory-pressure
warnings pause new recordings (finishing or cancelling the current one still
works); models are never silently unloaded. An 8 GB edition would need a
smaller cleanup model and its own quality and memory tests; the app does not
substitute one.

## Models and settings

- **Whisper large-v3-turbo Q5_0** (574 MB), English forced, translation off,
  Metal with whisper.cpp flash attention, kept loaded, never evicted.
- **Qwen 2.5 7B** from the `qwen2.5:7b` tag, imported with the exact Modelfile
  from `voxtype-llm-wrapper` at commit `27feaad731a3d9492dd1f31bb3d19a79cfc523ad`
  (byte-for-byte). Temperature 0, context 4096, output capped at 2048 tokens.
  Truncated, malformed, failed, or empty results fall back to the raw
  transcript. Measured cleanup latency on an M1 Max: 0.4–0.5 s for a
  sentence, about 4 s for 300 words.
- Ollama runs only on `127.0.0.1:11439` with `keep_alive=-1`, one loaded model,
  one parallel request, flash attention, a Q8 KV cache, and startup pruning
  disabled. If something already listens on that port, start fails rather than
  attaching to another server.

## Privacy

No cloud transcription, telemetry, or transcript history. VoxType pipes each
transcript over stdin to the compiled `VoxClean` helper, which calls the private
local Ollama API and writes only the result to stdout; text is never placed in
a shell command, argv, or a log. VoxType's info/debug logging is suppressed
(`RUST_LOG=warn`), and its upstream default of posting a transcript preview as
a macOS notification is turned off. Engine diagnostics go to an owner-only
`engine.log` that is reset on every launch. Ollama may create its standard
identity key in `~/.ollama`; the model store and server are otherwise isolated.

## Configuration

Everything lives in `~/Library/Application Support/BellowFlow/`: `config.toml`
(VoxType's configuration, generated once and then preserved), `engine.log`,
`models-v1` (the Ollama store), and `run` (runtime state). Use the setup
window's "Open configuration and diagnostic log" button, then quit and restart
to apply edits. VoxType is started with `--config`, which replaces rather than
merges `~/.config/voxtype`, so an existing VoxType installation is untouched.
Do not enable VoxType's own hotkey or OSD in this managed configuration.

The generated defaults, each verified against the pinned VoxType source
(unknown keys are silently ignored upstream, so `tests/test_config_template.py`
pins them):

| Section | Setting | Why |
| --- | --- | --- |
| top level | `engine = "whisper"`, `state_file = "auto"` | Explicit engine; state file under the private runtime directory the app watches. |
| `[hotkey]` | `enabled = false` | BellowFlow registers ⌃⌥Space itself via Carbon, so no Input Monitoring is needed. |
| `[osd]` | `enabled = false` | BellowFlow draws its own overlay. |
| `[audio]` | `device = "default"`, `sample_rate = 16000`, `max_duration_secs = 120` | Safety cap; the recording is transcribed at the limit. |
| `[whisper]` | `mode = "local"`, absolute model path, `language = "en"`, `translate = false`, `flash_attention = true` | Bundled model only, English forced, flash attention on Metal. |
| `[whisper]` | `on_demand_loading = false`, `gpu_isolation = false`, `max_loaded_models = 1`, `cold_model_timeout_secs = 0` | Whisper stays loaded until quit. |
| `[output]` | `mode = "type"`, `fallback_to_clipboard = true`, `auto_submit = false` | CGEvent typing, then AppleScript, then clipboard; never a stray Enter. |
| `[output.notification]` | all `false` | Keeps transcripts out of Notification Center. |
| `[output.post_process]` | `command = "exec '<VoxClean>'"`, `timeout_ms = 60000`, `trim = true`, `fallback_on_empty = true` | VoxClean's own 56 s timeout expires first, so the raw transcript still lands. |

Everything else keeps the pinned VoxType default (filler-word filtering on, VAD
off, no audio feedback).

## Architecture

The AppKit/SwiftUI shell (`Sources/BellowFlow`) owns a private VoxType daemon and
a bundled Ollama process, both terminated on quit. It registers the global
shortcut with Carbon, drives VoxType through `voxtype record toggle|cancel`,
watches VoxType's state file to draw a nonactivating overlay, and monitors
memory pressure. `Sources/VoxClean` is the post-processing helper. The setup
window floats above other windows until the app is ready, so it stays
reachable while permissions are being granted in System Settings.

Pinned upstreams: VoxType `320a737e5d3c8662e0ec7de95f75407baa784d82`, Ollama
`v0.11.10`, Whisper Q5 weights and the Ollama archive verified by SHA-256.
`models/inventory.json` inside the app records the exact model content hashes of
each build; the `qwen2.5:7b` tag is resolved at build time, so freeze that
manifest before a final release.

## Build

Build machine only (users need none of this): Xcode Command Line Tools, Swift
5.9+, Rust/Cargo, CMake, Git, Python 3.11+, internet, and roughly 30 GB free.

```sh
xcode-select --install
brew install rust cmake python
./scripts/build-macos.sh
```

The builder compiles VoxType with Metal, compiles both Swift executables, runs
the tests, verifies download hashes, thins the universal Ollama binary to arm64
(dropping its x86_64-only CPU backends), imports the Modelfile, copies only the
referenced model blobs, audits linked libraries, stamps the version from
`VERSION`, signs nested code, verifies the signature, and writes:

```
dist/BellowFlow-<VERSION>-macOS-arm64.dmg
dist/BellowFlow-<VERSION>-macOS-arm64.dmg.sha256
```

Downloads and the VoxType checkout are cached in `.cache/`; a rebuild with a
warm cache takes about 7 minutes, most of it DMG compression. The build's
Ollama server uses port 11439, so quit BellowFlow before building. Two
platform quirks are handled in the script: cargo fetches git dependencies with
the git CLI (SSH agents and `url.<base>.insteadOf` rewrites work), and clang's
compiler-rt is linked into VoxType because whisper.cpp's Objective-C Metal
backend needs it on current Xcode.

For a distributable signed and notarized build:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notary-profile' ./scripts/build-macos.sh
```

Without those, the build is ad-hoc signed: fine for development, but
rebuilding can invalidate earlier permission grants, and Gatekeeper requires
right-click → Open. Do not ship an ad-hoc build as a frictionless installer.

## Releases

`VERSION` is the single source of truth (`1.0.0-rc.1`): its numeric part
becomes `CFBundleShortVersionString`, the full label names the DMG, and the git
tag is `v<VERSION>`.

```sh
git tag v1.0.0-rc.1 && git push origin master v1.0.0-rc.1
```

`.github/workflows/macos.yml` builds Swift and runs the tests on every push and
pull request. On a `v*` tag (or a manual run with `bundle` enabled) it builds
the full DMG on a GitHub-hosted Apple Silicon runner, keeps the whole DMG as a
workflow artifact, and on tags publishes a **pre-release**. GitHub caps release
assets at 2 GB and the DMG is about 5.2 GB, so the release carries `split`
parts plus the `.sha256`; the Install section shows how to reassemble. If you
would rather offer one file, host the DMG elsewhere (Hugging Face, R2, S3) and
link it from the release notes. Building in CI needs the runner to download
several GB of models each time; no Apple signing secrets are assumed.

`.github/workflows/pages.yml` publishes `site/` and `scripts/install.sh` to
<https://xuancongwen.github.io/bellowflow/> on every push to `master` that
touches them. One-time setup: repository **Settings → Pages → Source: GitHub
Actions**.

## Homebrew

A cask template is in [`packaging/homebrew/bellowflow.rb`](packaging/homebrew/bellowflow.rb).
Homebrew downloads one file per cask, so it needs the whole DMG at a single
URL; the split parts on GitHub Releases will not do. Host the DMG on Hugging
Face, R2, S3, or similar (or shrink it under 2 GB by downloading models on first
launch), then:

1. Create a public repository named `homebrew-bellowflow` and copy the cask to
   `Casks/bellowflow.rb` with the real `url` and `sha256`.
2. Users install with
   `brew install --cask xuancongwen/bellowflow/bellowflow`. Check the cask
   with `brew audit --cask --online` and `brew style --cask` first.
3. Bump `version`, `url`, and `sha256` per release (`brew bump-cask-pr`, or a
   step in the release workflow).

Getting into the main `homebrew/cask` tap additionally needs a stable
(non-pre-release) version, a Developer ID signed and notarized app, and enough
public use to meet Homebrew's notability rules. Both remain on the
[validation list](#validation-status).

## Validation status

Verified on an Apple M1 Max, 64 GB, macOS 26.6, Swift 6.4:

- Both Swift executables compile; all nine Python tests pass with zero skips
  (model exporter, cleanup helper against an HTTP mock, config template).
- Full bundle built, `otool` audit and strict signature validation passed, DMG
  created; ad-hoc build launched from `dist/`.
- Microphone and Accessibility granted to the app; three dictations typed
  into a live application end to end through Whisper, VoxClean, and Ollama.
- Memory and latency profile of both engines (`docs/memory-profile.md`).
- Modelfile and VoxType license byte-identical to upstream; every generated
  config key and Ollama variable checked against the pinned sources.

Still open before a public 1.0:

1. Developer ID signing, notarization, Gatekeeper, and permission persistence
   across an update.
2. Memory pressure, swap, and latency on 16 GB and 24 GB Macs.
3. Offline first launch on a clean account; sleep/wake, screen changes,
   repeated launch/quit; forced engine failures and cleanup timeouts.
4. Prompt-quality benchmark of the Modelfile examples, including questions,
   commands, profanity, self-corrections, and injection-like dictated text.
5. Third-party license review, including a license for the Modelfile
   repository, which has none today.

## License and provenance

Application source: MIT. VoxType, Ollama, and Whisper: MIT. Qwen 2.5 7B:
Apache 2.0. The app bundles the upstream license texts. The Modelfile is copied
by explicit request from its author; settle its redistribution license before
public distribution. Full transitive dependency notices remain a release item.
