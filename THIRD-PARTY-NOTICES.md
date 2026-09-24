# Third-party notices

Bellow's own code is MIT licensed (see [LICENSE](LICENSE)). The app ships
or downloads the following components. Every one of them is under a permissive
open-source license; nothing copyleft, source-available, or non-commercial is
involved. The app bundle carries the license texts in
`Bellow.app/Contents/Resources/licenses/`.

## Shipped inside the app

| Component | What it is | License | Copyright | Text in bundle |
| --- | --- | --- | --- | --- |
| [VoxType](https://github.com/peteonrails/voxtype) `320a737e` | Dictation daemon (`bin/voxtype`), built from source with Metal | MIT | Peter Jackson | `VOXTYPE-LICENSE` |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and ggml | Speech-to-text engine, statically linked into VoxType via `whisper-rs-sys` | MIT | The ggml authors | `WHISPER-CPP-LICENSE` |
| Rust crates compiled into VoxType | 300-odd crates, listed with license and repository in [`docs/voxtype-crates.txt`](docs/voxtype-crates.txt) | MIT, Apache-2.0, BSD-2/3-Clause, ISC, Zlib, 0BSD, Unicode-3.0, Unlicense, CC0-1.0, CDLA-Permissive-2.0, BSL-1.0; `option-ext` is MPL-2.0 | Their respective authors | `VOXTYPE-CRATES.txt` |
| [Ollama](https://github.com/ollama/ollama) v0.34.4 | Local model server (`ollama/ollama`) and its llama.cpp runtime (`ollama/llama-server` and dylibs), from the official archive, arm64 slices only; the x86_64 CPU backends and MLX bundles are not shipped | MIT | Ollama | `OLLAMA-LICENSE`; the runtime's own notices ship beside it as `ollama/LLAMA_CPP_LICENSE`, `ollama/LLAMA_CPP_VENDORS_LICENSE`, `ollama/GO_LICENSE`, and the other `ollama/*_LICENSE` files |
| Cleanup Modelfiles | The `voxtype-llm-wrapper` prompt, examples, and parameters (`Modelfile.max`, `Modelfile.standard`), by Bellow's author | MIT, as part of this repository | Sam Wen | `BELLOW-LICENSE` |

`option-ext` (MPL-2.0) is used unmodified; its source is on crates.io and at
the repository named in the crate list, which satisfies the MPL's source
availability term for a file-level copyleft. All other licenses only require
attribution and inclusion of their text, which the bundle provides.

Apple frameworks (AppKit, SwiftUI, AVFoundation, Carbon, CryptoKit) are part of
macOS and are used under Apple's SDK terms; no Apple code is redistributed.

## Downloaded on first start

The app downloads these into `~/Library/Application Support/Bellow/`,
verified against the checksums and digests pinned in
[`Resources/models.json`](Resources/models.json).

| Model | Source | License | Copyright | Text in bundle |
| --- | --- | --- | --- | --- |
| Whisper large-v3-turbo (Q5_0 GGML) | [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp), converted from OpenAI's release | MIT | OpenAI | `WHISPER-LICENSE` |
| Qwen3.5-4B, text-only Q4_K_M GGUF, the Max tier | [unsloth/Qwen3.5-4B-GGUF on Hugging Face](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), converted by Unsloth from [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) | Apache-2.0 | Alibaba Cloud | `QWEN-LICENSE` |
| Qwen3.5-2B, text-only Q4_K_M GGUF, the Standard tier | [unsloth/Qwen3.5-2B-GGUF on Hugging Face](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF), converted by Unsloth from [Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) | Apache-2.0 | Alibaba Cloud | `QWEN-LICENSE` |

Only one of the two cleanup models is downloaded on a given Mac, chosen by its
memory tier or by the user. Both Qwen3.5 sizes are Apache 2.0 (the Qwen 2.5
3B, considered earlier, was not; check each size when changing models). The
raw GGUF carries no license layer in the Ollama store, so `QWEN-LICENSE` in
the bundle is the text of record.

## Keeping this current

- `./scripts/crate-licenses.sh .cache/voxtype > docs/voxtype-crates.txt`
  regenerates the crate list after bumping the VoxType pin.
- `scripts/build-macos.sh` copies every text above into the bundle, and
  `scripts/audit-bundle.py` fails the build if one is missing.
