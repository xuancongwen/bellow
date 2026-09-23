# Third-party notices

BellowFlow's own code is MIT licensed (see [LICENSE](LICENSE)). The app ships
or downloads the following components. Every one of them is under a permissive
open-source license; nothing copyleft, source-available, or non-commercial is
involved. The app bundle carries the license texts in
`BellowFlow.app/Contents/Resources/licenses/`.

## Shipped inside the app

| Component | What it is | License | Copyright | Text in bundle |
| --- | --- | --- | --- | --- |
| [VoxType](https://github.com/peteonrails/voxtype) `320a737e` | Dictation daemon (`bin/voxtype`), built from source with Metal | MIT | Peter Jackson | `VOXTYPE-LICENSE` |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and ggml | Speech-to-text engine, statically linked into VoxType via `whisper-rs-sys` | MIT | The ggml authors | `WHISPER-CPP-LICENSE` |
| Rust crates compiled into VoxType | 300-odd crates, listed with license and repository in [`docs/voxtype-crates.txt`](docs/voxtype-crates.txt) | MIT, Apache-2.0, BSD-2/3-Clause, ISC, Zlib, 0BSD, Unicode-3.0, Unlicense, CC0-1.0, CDLA-Permissive-2.0, BSL-1.0; `option-ext` is MPL-2.0 | Their respective authors | `VOXTYPE-CRATES.txt` |
| [Ollama](https://github.com/ollama/ollama) v0.11.10 | Local model server (`ollama/ollama`), the official arm64 binary | MIT | Ollama | `OLLAMA-LICENSE` |
| Cleanup Modelfile | The `voxtype-llm-wrapper` prompt and parameters (`Modelfile`), by BellowFlow's author | MIT, as part of this repository | Sam Wen | `BELLOWFLOW-LICENSE` |

`option-ext` (MPL-2.0) is used unmodified; its source is on crates.io and at
the repository named in the crate list, which satisfies the MPL's source
availability term for a file-level copyleft. All other licenses only require
attribution and inclusion of their text, which the bundle provides.

Apple frameworks (AppKit, SwiftUI, AVFoundation, Carbon, CryptoKit) are part of
macOS and are used under Apple's SDK terms; no Apple code is redistributed.

## Downloaded on first start

The app downloads these into `~/Library/Application Support/BellowFlow/`,
verified against the checksums and digests pinned in
[`Resources/models.json`](Resources/models.json).

| Model | Source | License | Copyright | Text in bundle |
| --- | --- | --- | --- | --- |
| Whisper large-v3-turbo (Q5_0 GGML) | [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp), converted from OpenAI's release | MIT | OpenAI | `WHISPER-LICENSE` |
| Qwen2.5-7B-Instruct (`qwen2.5:7b`) | [Ollama registry](https://ollama.com/library/qwen2.5), from [Qwen/Qwen2.5-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct) | Apache-2.0 | Alibaba Cloud | `QWEN-LICENSE` |

The Qwen 2.5 7B model is Apache 2.0; note that the 3B and 72B sizes of the
same family use different licenses, so keep the 7B pin if you change models.
The Ollama copy of the model carries the Apache 2.0 text as a license layer,
and the app's import keeps it.

## Keeping this current

- `./scripts/crate-licenses.sh .cache/voxtype > docs/voxtype-crates.txt`
  regenerates the crate list after bumping the VoxType pin.
- `scripts/build-macos.sh` copies every text above into the bundle, and
  `scripts/audit-bundle.py` fails the build if one is missing.
