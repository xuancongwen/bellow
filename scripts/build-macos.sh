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
# VERSION holds the release label (e.g. 1.0.0-rc.1). Its numeric prefix becomes
# CFBundleShortVersionString; the full label names the DMG and the git tag (v<label>).
RELEASE="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "VERSION must look like 1.0.0 or 1.0.0-rc.1 (got '$RELEASE')" >&2; exit 1; }
SHORT_VERSION="${RELEASE%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
DMG="$ROOT/dist/BellowFlow-$RELEASE-macOS-arm64.dmg"
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
mkdir -p "$RES/bin" "$RES/ollama" "$RES/licenses" "$APP/Contents/MacOS"
cp "$BIN/BellowFlow" "$BIN/VoxClean" "$APP/Contents/MacOS/"
cp "$CACHE/voxtype/target/release/voxtype" "$RES/bin/"
# Models are not bundled: the app downloads the ones pinned in models.json on first start.
cp Resources/Modelfile Resources/models.json "$RES/"
cp Resources/VOXTYPE-LICENSE "$RES/licenses/"
cp LICENSE "$RES/licenses/BELLOWFLOW-LICENSE"
cp THIRD-PARTY-NOTICES.md "$RES/licenses/THIRD-PARTY-NOTICES.md"
# whisper.cpp (MIT) is vendored by whisper-rs-sys and statically linked into voxtype.
WHISPER_CPP_LICENSE="$(find ~/.cargo/registry/src -path '*/whisper-rs-sys-*/whisper.cpp/LICENSE' | sort | tail -1)"
[[ -f "$WHISPER_CPP_LICENSE" ]] || { echo 'whisper.cpp LICENSE not found in the cargo registry' >&2; exit 1; }
cp "$WHISPER_CPP_LICENSE" "$RES/licenses/WHISPER-CPP-LICENSE"
./scripts/crate-licenses.sh "$CACHE/voxtype" > "$RES/licenses/VOXTYPE-CRATES.txt"
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
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
curl --fail --location 'https://raw.githubusercontent.com/ollama/ollama/v0.11.10/LICENSE' -o "$RES/licenses/OLLAMA-LICENSE"
curl --fail --location 'https://raw.githubusercontent.com/openai/whisper/main/LICENSE' -o "$RES/licenses/WHISPER-LICENSE"
curl --fail --location 'https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/raw/main/LICENSE' -o "$RES/licenses/QWEN-LICENSE"
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
rm -f "$ROOT"/dist/BellowFlow-*-macOS-arm64.dmg "$ROOT"/dist/BellowFlow-*-macOS-arm64.dmg.sha256
hdiutil create -volname "BellowFlow $RELEASE" -srcfolder "$APP" -ov -format UDZO "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built: $DMG ($SHORT_VERSION build $BUILD_NUMBER)"
