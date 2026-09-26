# Bellow

A native macOS menu-bar dictation app. Press **Control + Option + X**, speak,
press it again, and the cleaned-up English text is typed into whatever app has
focus. Everything runs on your Mac: it bundles [VoxType](https://github.com/peteonrails/voxtype)
and a private [Ollama](https://github.com/ollama/ollama) server, and on first
start downloads Whisper large-v3-turbo and a Qwen3.5 cleanup model sized to
the Mac's memory, with Sam Wen's
[cleanup Modelfiles](https://github.com/xuancongwen/voxtype-llm-wrapper).
MIT-licensed application code. Apple Silicon, macOS 13 or newer. Formerly
known as VoxBundle.

**Status: 1.0.0-rc.7 — builds, packages, and dictates end to end on an
Apple Silicon Mac with either cleanup model; Developer ID signed and notarized
by Apple since rc.6; the 8 GB and 16 GB tiers are not yet measured on real
Macs.** See
[Validation status](#validation-status) for exactly what has and has not been
checked.

## Install

Website: **<https://xuancongwen.github.io/bellow/>**

The app is a 24 MB download (51 MB installed, most of it the Ollama engine);
it fetches its models on first start: 0.6 GB for speech plus 2.7 GB (Max) or
1.3 GB (Standard) for cleanup.

1. Download `Bellow-<version>-macOS-arm64.dmg` from the
   [latest release](https://github.com/xuancongwen/bellow/releases).
2. Open it and drag **Bellow** to **Applications**.
3. Open **Bellow** from Applications. The app is Developer ID signed and
   notarized by Apple, so Gatekeeper opens it without a warning.
4. In the setup window, allow **Microphone** and **Accessibility** and click
   **Start**. The first start downloads the models (resumes if interrupted);
   the status reads **Ready · ⌃⌥X to dictate** when done. Later launches
   start on their own.

Prefer the terminal? This does steps 1 to 3 for you, including checksum
verification:

```sh
curl -fsSL https://xuancongwen.github.io/bellow/install.sh | bash
```

The script is [`scripts/install.sh`](scripts/install.sh);
`BELLOW_VERSION=v1.0.0-rc.7` pins a release. To verify a manual download,
fetch the `.sha256` file next to the DMG and run `shasum -a 256 -c` on it.
A Homebrew cask is drafted (see [Homebrew](#homebrew)).

Dictate: press ⌃⌥X, speak, press it again. A small overlay shows
listening (with a live microphone level, so you can see your voice is being
picked up), transcribing, and cleaning up. Do not switch windows while it is
typing. Quit from the menu bar to release the models.

To use a different shortcut, open **Setup and status…** from the menu bar,
click **Change…** next to the shortcut, and press the new combination (it
needs Control, Option, or Command; Escape keeps the old one). It takes
effect immediately and is remembered; **Reset** returns to ⌃⌥X.

No Homebrew, Python, Rust, Ollama installation, account, or API key is needed.
The only network use is the one-time model download on first start; dictation
itself never touches the network. Recording is toggle, not hold-to-talk; a
recording is transcribed automatically at 120 seconds.

## System requirements

Measured with the shipped binaries and settings (`docs/memory-profile.md`):

| | |
| --- | --- |
| Chip | Apple Silicon (Metal). Intel is not supported. |
| macOS | 13 Ventura or newer |
| Memory | **8 GB minimum; more than 16 GB gets the Max model.** With the app's Ollama settings the cleanup runner is 3.1 GB resident for Max (Qwen3.5 4B) and 1.5 GB for Standard (Qwen3.5 2B); Whisper holds 0.64 GB and peaks at 0.86 GB. The rc.4 figures for Qwen 2.5 7B are in `docs/memory-profile.md`. |
| Disk | About 3.4 GB (Max) or 2 GB (Standard): the app plus the downloaded models; the weights are hard-linked into the Ollama store, not copied |

The app reads the Mac's physical memory at launch and sorts it into one of
two tiers pinned in `Resources/models.json`; the tier picks the cleanup
model. The chip is logged but not used: on Apple Silicon every generation
shares the same unified-memory rules (macOS lets the GPU wire about two thirds
of RAM up to 36 GB, three quarters above), so the chip changes speed, not
whether a model fits.

| Tier | Memory | Cleanup model |
| --- | --- | --- |
| max | more than 16 GB (18 GB and up) | Qwen3.5 4B, needs 16 GB |
| standard | 16 GB and below | Qwen3.5 2B, needs 8 GB |

A tier without a pinned model would be served by the next larger tier's
model when the Mac meets that model's floor (`needsGiB`); with both tiers
pinned this only matters for future editions. Each pinned model carries its own
admission estimate: Max requires 7 GiB of reclaimable memory at start (a
5 GiB working-set allowance plus 2 GiB reserve) and Standard 4.5 GiB (3.5 plus
1), against measured resident sizes of about 4 GB and 2.4 GB including
Whisper. This is an admission policy,
not an enforceable cap: macOS can still compress or page model memory under
pressure, and nothing is `mlock`ed. Memory-pressure warnings pause new
recordings (finishing or cancelling the current one still works); models are
never silently unloaded.

In the app the tiers appear as **Max** and **Standard**. The
setup window shows the model in use and a **Change…** button; the sheet
behind it explains each choice in plain language, greys out the ones this Mac
cannot run (too little memory, or not included in this version yet), and
defaults to **Automatic**. Choosing a model saves the choice, downloads that
model once, and restarts dictation. Status lines say "Downloading the Max
model" rather than naming files.

`Bellow.app/Contents/MacOS/Bellow --hardware` prints the chip, memory,
tier, choice, model, and admission verdict. `BELLOW_MEMORY_GIB=8` makes
the app pretend it has that much RAM, and `BELLOW_TIER=standard` (or `auto`)
overrides the saved choice, to exercise the other tiers on a larger Mac.
Whisper is shared by every tier.

## Models and settings

Models are not in the app. On first start it downloads exactly the ones pinned
in [`Resources/models.json`](Resources/models.json): Whisper from Hugging Face,
verified against its SHA-256, and the base model for this Mac's tier through
the bundled Ollama from the Ollama registry, whose pulled manifest must list
exactly the pinned blob digests (otherwise the app refuses it and asks for an
update). Both live in `~/Library/Application Support/Bellow/`; downloads resume
if interrupted, and later starts only check that the files are in place.
`./scripts/pin-models.py <tier> <weights.gguf> <whisper.bin>` regenerates the
pins for one tier from the downloaded files, taking the URL and expected
checksum from the tier's Modelfile.

- **Whisper large-v3-turbo Q5_0** (574 MB), English forced, translation off,
  Metal with whisper.cpp flash attention, kept loaded, never evicted.
- **Max: Qwen3.5 4B** and **Standard: Qwen3.5 2B**, both Unsloth's
  text-only Q4_K_M GGUF conversions from Hugging Face (the Ollama library
  builds bundle a vision tower that costs 1.3 to 2 GB of memory and does
  nothing for dictation). The GGUF is downloaded and checksummed like Whisper,
  hard-linked into the private Ollama store under its digest, and the wrapper
  is built from `Modelfile.max` or `Modelfile.standard` with only the FROM
  line pointed at that file. Both Modelfiles are byte-for-byte the ones in
  `voxtype-llm-wrapper` at commit `7528c16`, which renders one shared system
  prompt and example set onto each base model; the app rebuilds a wrapper
  whenever its Modelfile or weights change. Temperature 0, context 4096,
  output capped at 2048 tokens, and every request sets `think: false`: Ollama
  applies the GGUF's own chat template (thinking on) rather than the
  Modelfile's, and without that flag the model reasons for 2048 tokens and
  returns nothing. Truncated, malformed, failed, or empty results fall back to
  the raw transcript. On upstream's 57 scored test cases, sent exactly as the
  app sends them, Max passes 50 with 5 near misses (punctuation only) and 2
  failures; Standard passes 44 with 3 near misses and 10 failures, mostly
  unresolved self-corrections. Measured on an M1 Max: about 0.5 s per
  sentence for Max, 0.2 s for Standard.
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
The first start connects to huggingface.co and registry.ollama.ai to fetch the
models; nothing else ever leaves the machine.

## Configuration

Everything lives in `~/Library/Application Support/Bellow/`: `config.toml`
(VoxType's configuration, generated once and then preserved), `engine.log`,
`models-v1` (the Ollama store), and `run` (runtime state). Use the setup
window's "Open configuration and diagnostic log" button, then quit and restart
to apply edits. VoxType is started with `--config`, which replaces rather than
merges `~/.config/voxtype`, so an existing VoxType installation is untouched.
Do not enable VoxType's own hotkey or OSD in this managed configuration. A directory left by the app's old name, `BellowFlow`, is moved to `Bellow` on first start, with the paths inside `config.toml` and the saved shortcut and model choice carried over, so nothing is downloaded or set up again.

The generated defaults, each verified against the pinned VoxType source
(unknown keys are silently ignored upstream, so `tests/test_config_template.py`
pins them):

| Section | Setting | Why |
| --- | --- | --- |
| top level | `engine = "whisper"`, `state_file = "auto"` | Explicit engine; state file under the private runtime directory the app watches. |
| `[hotkey]` | `enabled = false` | Bellow registers the shortcut itself via Carbon (⌃⌥X by default, changeable in the setup window), so no Input Monitoring is needed. |
| `[osd]` | `enabled = false` | Bellow draws its own overlay. |
| `[audio]` | `device = "default"`, `sample_rate = 16000`, `max_duration_secs = 120` | Safety cap; the recording is transcribed at the limit. |
| `[whisper]` | `mode = "local"`, absolute model path, `language = "en"`, `translate = false`, `flash_attention = true` | Bundled model only, English forced, flash attention on Metal. |
| `[whisper]` | `on_demand_loading = false`, `gpu_isolation = false`, `max_loaded_models = 1`, `cold_model_timeout_secs = 0` | Whisper stays loaded until quit. |
| `[output]` | `mode = "type"`, `fallback_to_clipboard = true`, `auto_submit = false` | CGEvent typing, then AppleScript, then clipboard; never a stray Enter. |
| `[output.notification]` | all `false` | Keeps transcripts out of Notification Center. |
| `[output.post_process]` | `command = "exec '<VoxClean>'"`, `timeout_ms = 60000`, `trim = true`, `fallback_on_empty = true` | VoxClean's own 56 s timeout expires first, so the raw transcript still lands. |

Everything else keeps the pinned VoxType default (filler-word filtering on, VAD
off, no audio feedback).

## Architecture

The AppKit/SwiftUI shell (`Sources/Bellow`) owns a private VoxType daemon and
a bundled Ollama process, both terminated on quit. It registers the global
shortcut with Carbon, drives VoxType through `voxtype record toggle|cancel`,
watches VoxType's state file to draw a nonactivating overlay, and monitors
memory pressure. `Sources/VoxClean` is the post-processing helper. The setup
window floats above other windows until the app is ready, so it stays
reachable while permissions are being granted in System Settings.

`Sources/Bellow/Models.swift` downloads and verifies the models;
`Bellow --prepare-models` runs that step headless (with
`BELLOW_SUPPORT=<dir>` to relocate the data directory), which is how the
download path is tested without the UI.

Pinned upstreams: VoxType `320a737e5d3c8662e0ec7de95f75407baa784d82`, Ollama
`v0.34.4` (archive verified by SHA-256; Qwen3.5 needs a 2026 llama.cpp, so
the rc.4 pin of 0.11.10 cannot load these models), and the model checksums
in `Resources/models.json`.

## Build

Build machine only (users need none of this): Xcode Command Line Tools, Swift
5.9+, Rust/Cargo, CMake, Git, Python 3.11+, internet, and a few GB free.

```sh
xcode-select --install
brew install rust cmake python
./scripts/build-macos.sh
```

The builder compiles VoxType with Metal, compiles both Swift executables, runs
the tests, verifies the Ollama download hash, thins the universal Ollama binary
to arm64 (dropping its x86_64-only CPU backends), audits linked libraries and
the model spec, renders the app icon (`scripts/make-icon.swift`), stamps the
version from `VERSION`, signs nested code, verifies the signature, and writes
the DMG:

```
dist/Bellow-<VERSION>-macOS-arm64.dmg
dist/Bellow-<VERSION>-macOS-arm64.dmg.sha256
```

Downloads and the VoxType checkout are cached in `.cache/`; a rebuild with a
warm cache takes about two minutes.

### Checks

`./scripts/check.sh` runs what the CI build job used to run on every push:
the release build, the Python tests, the Swift tests, and a syntax check of
the shell scripts, in about 30 seconds with a warm `.build/`. To run it
automatically before every `git push`, point git at the versioned hooks once
per clone (`git push --no-verify` skips it for one push):

```sh
git config core.hooksPath scripts/hooks
```

Two
platform quirks are handled in the script: cargo fetches git dependencies with
the git CLI (SSH agents and `url.<base>.insteadOf` rewrites work), and clang's
compiler-rt is linked into VoxType because whisper.cpp's Objective-C Metal
backend needs it on current Xcode.

### Signing and notarization

Releases from 1.0.0-rc.6 on are Developer ID signed and notarized: the app
and the DMG are both submitted to Apple and stapled, so Gatekeeper opens them
without a warning. Without a certificate the build is ad-hoc signed: fine for
development, but Gatekeeper blocks the first launch until the user allows it
in Privacy & Security, and each rebuild can invalidate earlier permission
grants. The one-time setup for a Mac that signs releases:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/)
   (US$99 per year; a personal membership is enough).
2. Create a **Developer ID Application** certificate: Xcode → Settings →
   Accounts → Manage Certificates → **+**, or at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list).
   It lands in your login keychain as `Developer ID Application: Your Name (TEAMID)`.
3. Create an app-specific password for notarization at
   [account.apple.com](https://account.apple.com/account/manage) → Sign-In and
   Security → App-Specific Passwords.

Build on your Mac:

```sh
xcrun notarytool store-credentials bellow --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' NOTARY_PROFILE=bellow ./scripts/build-macos.sh
```

Build in CI: export the certificate from Keychain Access as a `.p12` with a
password, then add five repository secrets (Settings → Secrets and variables
→ Actions): `APPLE_CERTIFICATE_P12` (`base64 -i cert.p12 | pbcopy`),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and
`APPLE_APP_SPECIFIC_PASSWORD`. With all five set, the next tag produces a
signed, notarized, stapled app and DMG and the release notes say so; with any
missing, the build stays ad-hoc.

The script signs every nested Mach-O with the hardened runtime and the
entitlements in `Resources/Entitlements.plist` (only `audio-input`), submits
the app and then the DMG to Apple, staples both, and checks the result with
`spctl`. Switching from an ad-hoc to a Developer ID signature changes the app's
identity, so macOS asks for Microphone and Accessibility once more on the
first signed build.

## Releases

`VERSION` is the single source of truth (`1.0.0-rc.7`): its numeric part
becomes `CFBundleShortVersionString`, the full label names the DMG, and the git
tag is `v<VERSION>`. A release is cut on a Mac with the signing certificate
(see [Signing and notarization](#signing-and-notarization)), then published
with the `gh` CLI, which creates the tag:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' NOTARY_PROFILE=bellow ./scripts/build-macos.sh
git push origin master
gh release create v<VERSION> --prerelease --target master dist/Bellow-<VERSION>-macOS-arm64.dmg dist/Bellow-<VERSION>-macOS-arm64.dmg.sha256
```

`.github/workflows/macos.yml` does not run on ordinary pushes: macOS runners
are billed at ten times the Linux rate, so the build and tests run locally
instead (see [Checks](#checks)). It builds Swift and runs the tests on pull
requests and manual runs, and on a `v*` tag (or a manual run with `bundle`
enabled) it can build the DMG on a GitHub-hosted Apple Silicon runner and
publish a pre-release, signed if the five Apple secrets are set. That path is
a fallback; the local build above is the normal one.

The website at <https://xuancongwen.github.io/bellow/> is `site/` plus
`scripts/install.sh`, served by GitHub Pages from the `gh-pages` branch.
`./scripts/publish-site.sh` assembles that branch and force-pushes it; run it
after changing either. It does not use GitHub Actions. One-time setup, already
done for this repository: **Settings → Pages → Source: Deploy from a branch**,
branch `gh-pages`, folder `/`.

## Homebrew

A cask is drafted in [`packaging/homebrew/bellow.rb`](packaging/homebrew/bellow.rb);
it downloads the DMG straight from the GitHub release.

1. Create a public repository named `homebrew-bellow` and copy the cask to
   `Casks/bellow.rb` with the `sha256` from the release's `.sha256` file.
2. Users install with
   `brew install --cask xuancongwen/bellow/bellow`. Check the cask
   with `brew audit --cask --online` and `brew style --cask` first.
3. Bump `version`, `url`, and `sha256` per release (`brew bump-cask-pr`, or a
   step in the release workflow).

Getting into the main `homebrew/cask` tap additionally needs a stable
(non-pre-release) version and enough public use to meet Homebrew's notability
rules; the app is already Developer ID signed and notarized.

## Validation status

Verified on an Apple M1 Max, 64 GB, macOS 26.6, Swift 6.4:

- Both Swift executables compile; all nine Python tests pass with zero skips
  (model exporter, cleanup helper against an HTTP mock, config template).
- Bundle built, `otool` audit and strict signature validation passed, DMG
  created; ad-hoc build launched from `dist/`.
- Developer ID signed with the hardened runtime on every nested binary; the
  app and the DMG accepted by Apple's notary service and stapled; `spctl`
  accepts a quarantined copy as "Notarized Developer ID" (rc.6).
- Model download (`--prepare-models`): Whisper fetched from Hugging Face and
  checksum-verified; the Ollama pull streamed and completed; a model whose
  digests differ from `models.json` is refused; the wrapper is re-created from
  the Modelfile; a second run with everything in place is a no-op.
- Microphone and Accessibility granted to the app; three dictations typed
  into a live application end to end through Whisper, VoxClean, and Ollama.
- Memory and latency profile of both engines (`docs/memory-profile.md`).
- Modelfile and VoxType license byte-identical to upstream; every generated
  config key and Ollama variable checked against the pinned sources.
- License audit: every crate in the VoxType build, whisper.cpp, Ollama, both
  models, and the Modelfile checked (`THIRD-PARTY-NOTICES.md`).

Still open before a public 1.0:

1. Microphone and Accessibility grants persisting across an update from one
   signed build to the next (the ad-hoc to Developer ID switch resets them
   once).
2. Memory pressure, swap, and latency on 16 GB and 24 GB Macs.
3. First launch on a clean account through the setup window (the download
   path has only been exercised headless); sleep/wake, screen changes,
   repeated launch/quit; forced engine failures and cleanup timeouts.
4. Prompt-quality benchmark of the Modelfile examples, including questions,
   commands, profanity, self-corrections, and injection-like dictated text.
5. Add a LICENSE file to the `voxtype-llm-wrapper` repository so the
   Modelfile is MIT at its source too (it is already MIT here).

## License and provenance

Everything is open source under permissive licenses; nothing copyleft or
non-commercial is involved.

| Component | License |
| --- | --- |
| Bellow source, including the cleanup Modelfile (by Bellow's author) | MIT |
| VoxType, whisper.cpp/ggml, Ollama, Whisper large-v3-turbo weights | MIT |
| Rust crates compiled into VoxType (listed in `docs/voxtype-crates.txt`) | MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0, Unlicense, CC0, CDLA-Permissive, BSL-1.0; one MPL-2.0 crate used unmodified |
| Qwen2.5-7B-Instruct | Apache-2.0 |

[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) has the full table with
copyright holders and sources. The app bundles every license text in
`Contents/Resources/licenses/`, and the build fails if one is missing or a
crate's license is not permissive. The Modelfile is byte-identical to
`voxtype-llm-wrapper`, which has no license file of its own; it is Sam Wen's
work and is licensed here under this repository's MIT license.
