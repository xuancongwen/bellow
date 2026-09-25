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
APP="$ROOT/dist/Bellow.app"
# VERSION holds the release label (e.g. 1.0.0-rc.1). Its numeric prefix becomes
# CFBundleShortVersionString; the full label names the DMG and the git tag (v<label>).
RELEASE="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "VERSION must look like 1.0.0 or 1.0.0-rc.1 (got '$RELEASE')" >&2; exit 1; }
SHORT_VERSION="${RELEASE%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
DMG="$ROOT/dist/Bellow-$RELEASE-macOS-arm64.dmg"
RES="$APP/Contents/Resources"
mkdir -p "$CACHE" "$ROOT/dist"
fetch() {
  local url="$1" target="$2" hash="$3"
  if [[ -f "$target" ]] && echo "$hash  $target" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
  curl --fail --location --retry 3 "$url" -o "$target.partial"
  echo "$hash  $target.partial" | shasum -a 256 -c -
  mv "$target.partial" "$target"
}
fetch 'https://github.com/ollama/ollama/releases/download/v0.34.4/ollama-darwin.tgz' "$CACHE/ollama.tgz" 'e9c8fddaab5f48f47f2c4ae3d23d0732f5182417125353faeed2188e34a22799'
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
swift test 2>&1 | grep -E "Executed|error:" | tail -3
rm -rf "$APP"
mkdir -p "$RES/bin" "$RES/ollama" "$RES/licenses" "$APP/Contents/MacOS"
cp "$BIN/Bellow" "$BIN/VoxClean" "$APP/Contents/MacOS/"
cp "$CACHE/voxtype/target/release/voxtype" "$RES/bin/"
# Models are not bundled: the app downloads the ones pinned in models.json on first start.
# One Modelfile per memory tier (Modelfile.max, Modelfile.standard), named in models.json; byte-identical to voxtype-llm-wrapper.
cp Resources/Modelfile.* Resources/models.json "$RES/"
cp Resources/VOXTYPE-LICENSE "$RES/licenses/"
cp LICENSE "$RES/licenses/BELLOW-LICENSE"
cp THIRD-PARTY-NOTICES.md "$RES/licenses/THIRD-PARTY-NOTICES.md"
# whisper.cpp (MIT) is vendored by whisper-rs-sys and statically linked into voxtype.
WHISPER_CPP_LICENSE="$(find ~/.cargo/registry/src -path '*/whisper-rs-sys-*/whisper.cpp/LICENSE' | sort | tail -1)"
[[ -f "$WHISPER_CPP_LICENSE" ]] || { echo 'whisper.cpp LICENSE not found in the cargo registry' >&2; exit 1; }
cp "$WHISPER_CPP_LICENSE" "$RES/licenses/WHISPER-CPP-LICENSE"
./scripts/crate-licenses.sh "$CACHE/voxtype" > "$RES/licenses/VOXTYPE-CRATES.txt"
tar -xzf "$CACHE/ollama.tgz" -C "$RES/ollama"
# The official archive holds universal ollama, llama-server, and llama-quantize binaries; the
# x86_64 slice's shared libraries (*.dylib, x86_64-only, plus version symlinks) and CPU backends
# (*.so); MLX bundles (mlx_metal_*, ~330 MB, not used for GGUF models); and the license texts.
# The arm64 llama-server is self-contained (Metal built in, no @rpath dylibs), so this bundle
# keeps the two arm64 binaries and the licenses and drops everything else.
[[ -x "$RES/ollama/ollama" && -x "$RES/ollama/llama-server" ]] || { echo 'Unexpected Ollama archive layout' >&2; exit 1; }
rm -rf "$RES/ollama"/mlx_metal_* "$RES/ollama"/*.so "$RES/ollama"/llama-quantize
while IFS= read -r -d '' entry; do
  if [[ "$(file -b "$entry")" != *Mach-O* ]]; then continue; fi
  if ! lipo -archs "$entry" | grep -qw arm64; then rm -f "$entry"; continue; fi
  if [[ "$(lipo -archs "$entry")" == *x86_64* ]]; then
    lipo "$entry" -thin arm64 -output "$entry.arm64" && mv "$entry.arm64" "$entry" && chmod 755 "$entry"
  fi
done < <(find "$RES/ollama" -type f -print0)
# Symlinks left pointing at removed x86_64 dylibs would fail codesign --strict.
find "$RES/ollama" -type l ! -exec test -e {} \; -delete
for bin in ollama llama-server; do
  if otool -L "$RES/ollama/$bin" | tail -n +2 | awk '{print $1}' | grep -qv '^/System/\|^/usr/lib/'; then
    echo "$bin depends on a bundled library this build does not ship" >&2; exit 1
  fi
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$ROOT/dist/AppIcon.iconset"
iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$RES/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
curl --fail --location 'https://raw.githubusercontent.com/ollama/ollama/v0.34.4/LICENSE' -o "$RES/licenses/OLLAMA-LICENSE"
curl --fail --location 'https://raw.githubusercontent.com/openai/whisper/main/LICENSE' -o "$RES/licenses/WHISPER-LICENSE"
# Both cleanup models are Qwen3.5 (Apache 2.0); the 4B and 2B repositories carry the same text.
curl --fail --location 'https://huggingface.co/Qwen/Qwen3.5-4B/raw/main/LICENSE' -o "$RES/licenses/QWEN-LICENSE"
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
# Notarize with either a stored keychain profile (NOTARY_PROFILE, for a developer Mac) or
# Apple ID credentials in the environment (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD, for CI).
notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait; fi
}
NOTARIZE=0
if [[ -n "${NOTARY_PROFILE:-}" || -n "${NOTARY_APPLE_ID:-}" ]]; then
  [[ "$IDENTITY" != "-" ]] || { echo 'Notarization needs SIGNING_IDENTITY (a Developer ID Application certificate).' >&2; exit 1; }
  NOTARIZE=1
  ditto -c -k --keepParent "$APP" "$ROOT/dist/notarize.zip"
  notarize "$ROOT/dist/notarize.zip"
  xcrun stapler staple "$APP"
  rm "$ROOT/dist/notarize.zip"
  spctl --assess --type execute --verbose=2 "$APP"
fi
rm -f "$ROOT"/dist/Bellow-*-macOS-arm64.dmg "$ROOT"/dist/Bellow-*-macOS-arm64.dmg.sha256
# The DMG holds the app next to an Applications shortcut, so installing is one drag.
STAGE="$ROOT/dist/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Bellow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Bellow $RELEASE" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [[ "$NOTARIZE" == 1 ]]; then
  if [[ "$IDENTITY" != "-" ]]; then codesign --force --sign "$IDENTITY" "$DMG"; fi
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built: $DMG ($SHORT_VERSION build $BUILD_NUMBER)"
