#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=13.0
# Use the git CLI for cargo's git dependencies: libgit2 cannot use SSH agents or
# url.<base>.insteadOf rewrites that developer machines commonly configure.
export CARGO_NET_GIT_FETCH_WITH_CLI=true
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac. This first edition targets macOS 13+ on Apple Silicon.' >&2; exit 1; }
for tool in swift cargo cmake git curl python3 codesign; do
  command -v "$tool" >/dev/null || { echo "Missing build dependency: $tool. See README.md." >&2; exit 1; }
done
CACHE="$ROOT/.cache"
APP="$ROOT/dist/BellowFlow.app"
RES="$APP/Contents/Resources"
mkdir -p "$CACHE" "$ROOT/dist"
fetch() {
  local url="$1" target="$2" hash="$3"
  if [[ -f "$target" ]] && echo "$hash  $target" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
  curl --fail --location --retry 3 "$url" -o "$target.partial"
  echo "$hash  $target.partial" | shasum -a 256 -c -
  mv "$target.partial" "$target"
}
fetch 'https://github.com/ollama/ollama/releases/download/v0.11.10/ollama-darwin.tgz' "$CACHE/ollama.tgz" '6179e85eeca0f731390c8eb4d4bf83791526d4a6072370c312f3968077a5e63f'
fetch 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' "$CACHE/whisper.bin" '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2'
if [[ ! -d "$CACHE/voxtype/.git" ]]; then git clone https://github.com/peteonrails/voxtype.git "$CACHE/voxtype"; fi
git -C "$CACHE/voxtype" checkout --detach 320a737e5d3c8662e0ec7de95f75407baa784d82
# whisper.cpp's Objective-C Metal backend uses @available, which needs clang's compiler-rt
# (___isPlatformVersionAtLeast); rustc links with -nodefaultlibs, so add it explicitly.
CLANG_RT="$(clang --print-resource-dir)/lib/darwin/libclang_rt.osx.a"
[[ -f "$CLANG_RT" ]] || { echo "Missing $CLANG_RT; install Xcode Command Line Tools." >&2; exit 1; }
(cd "$CACHE/voxtype" && cargo rustc --release --locked --features gpu-metal --bin voxtype -- -C link-arg="$CLANG_RT")
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
python3 -m unittest discover -s tests -v
rm -rf "$APP"
mkdir -p "$RES/bin" "$RES/ollama" "$RES/models" "$RES/licenses" "$APP/Contents/MacOS"
cp "$BIN/BellowFlow" "$BIN/VoxClean" "$APP/Contents/MacOS/"
cp "$CACHE/voxtype/target/release/voxtype" "$RES/bin/"
cp "$CACHE/whisper.bin" "$RES/whisper.bin"
cp Resources/Modelfile "$RES/"
cp Resources/VOXTYPE-LICENSE "$RES/licenses/"
cp LICENSE "$RES/licenses/BELLOWFLOW-LICENSE"
tar -xzf "$CACHE/ollama.tgz" -C "$RES/ollama"
# The official archive is a universal ollama binary (Metal is linked into the arm64 slice)
# plus x86_64-only CPU backends. This bundle is arm64-only: thin the binary, drop the rest.
[[ -x "$RES/ollama/ollama" ]] || { echo 'Unexpected Ollama archive layout' >&2; exit 1; }
if [[ "$(lipo -archs "$RES/ollama/ollama")" == *x86_64* ]]; then
  lipo "$RES/ollama/ollama" -thin arm64 -output "$RES/ollama/ollama.arm64"
  mv "$RES/ollama/ollama.arm64" "$RES/ollama/ollama"
  chmod 755 "$RES/ollama/ollama"
fi
while IFS= read -r -d '' entry; do
  if ! lipo -archs "$entry" 2>/dev/null | grep -qw arm64; then rm -f "$entry"; fi
done < <(find "$RES/ollama" -type f ! -name ollama -print0)
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Use a private port and store while preparing the distributable models.
export OLLAMA_HOST='127.0.0.1:11439'
export OLLAMA_MODELS="$CACHE/models"
export OLLAMA_KEEP_ALIVE=-1
export OLLAMA_NUM_PARALLEL=1
if curl --max-time 1 -fsS http://127.0.0.1:11439/api/version >/dev/null 2>&1; then
  echo 'Quit BellowFlow or the listener on port 11439 before building.' >&2; exit 1
fi
mkdir -p "$OLLAMA_MODELS"
# Model blobs use our private store; Ollama may create its normal local identity file.
"$RES/ollama/ollama" serve >"$CACHE/ollama-build.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for ((i=0;i<120;i++)); do
  if curl --max-time 1 -fsS http://127.0.0.1:11439/api/version >/dev/null 2>&1; then break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$CACHE/ollama-build.log"; exit 1; }
  sleep 0.25
done
"$RES/ollama/ollama" pull qwen2.5:7b
"$RES/ollama/ollama" create voxtype-llm-wrapper -f Resources/Modelfile
# Only copy the referenced content-addressed blobs and manifests.
python3 scripts/package-models.py "$OLLAMA_MODELS" "$RES/models"
curl --fail --location 'https://raw.githubusercontent.com/ollama/ollama/v0.11.10/LICENSE' -o "$RES/licenses/OLLAMA-LICENSE"
curl --fail --location 'https://raw.githubusercontent.com/openai/whisper/main/LICENSE' -o "$RES/licenses/WHISPER-LICENSE"
curl --fail --location 'https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/raw/main/LICENSE' -o "$RES/licenses/QWEN-LICENSE"
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT
python3 scripts/audit-bundle.py "$APP"
# Sign nested Mach-O files individually, then the outer app. Stable identity matters for TCC.
IDENTITY="${SIGNING_IDENTITY:--}"
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q 'Mach-O'; then
    codesign --force --options runtime --sign "$IDENTITY" --entitlements Resources/Entitlements.plist "$path"
  fi
done < <(find "$APP/Contents" -type f -print0)
codesign --force --options runtime --sign "$IDENTITY" --entitlements Resources/Entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$ROOT/dist/notarize.zip"
  xcrun notarytool submit "$ROOT/dist/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ROOT/dist/notarize.zip"
fi
rm -f "$ROOT/dist/BellowFlow-macOS-arm64.dmg"
hdiutil create -volname BellowFlow -srcfolder "$APP" -ov -format UDZO "$ROOT/dist/BellowFlow-macOS-arm64.dmg"
echo "Built: $ROOT/dist/BellowFlow-macOS-arm64.dmg"
