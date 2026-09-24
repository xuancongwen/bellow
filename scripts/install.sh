#!/bin/bash
# BellowFlow installer for Apple Silicon Macs.
#
#   curl -fsSL https://xuancongwen.github.io/bellowflow/install.sh | bash
#
# Downloads the release DMG (or its split parts, for releases that exceeded GitHub's
# 2 GB asset cap), verifies the SHA-256, copies BellowFlow.app to /Applications,
# clears the quarantine flag (release candidates are ad-hoc signed, not notarized),
# and opens the app. The app itself downloads its models on first start. Set
# BELLOWFLOW_VERSION=v1.0.0-rc.4 to pin a release; the default is the newest
# release, pre-releases included. Downloads go to ~/Library/Caches/BellowFlow-installer
# and resume if the script is rerun.
set -euo pipefail

REPO="${BELLOWFLOW_REPO:-xuancongwen/bellowflow}"
DEST="${BELLOWFLOW_DEST:-/Applications}"
CACHE="${HOME}/Library/Caches/BellowFlow-installer"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "BellowFlow runs on macOS only."
[[ "$(uname -m)" == arm64 ]] || fail "BellowFlow needs an Apple Silicon Mac (M1 or newer)."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "BellowFlow needs macOS 13 Ventura or newer (you have $(sw_vers -productVersion))."
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
(( mem_gb >= 16 )) || fail "BellowFlow needs at least 16 GB of memory (this Mac has ${mem_gb} GB); the app refuses to load its models below that."
for tool in curl shasum hdiutil ditto xattr; do
  command -v "$tool" >/dev/null || fail "Missing $tool, which ships with macOS."
done

api="https://api.github.com/repos/${REPO}/releases"
if [[ -n "${BELLOWFLOW_VERSION:-}" ]]; then
  api="${api}/tags/${BELLOWFLOW_VERSION}"
  release_json="$(curl -fsSL "$api" 2>&1)" || fail "No release tagged ${BELLOWFLOW_VERSION} at https://github.com/${REPO}/releases (${release_json})"
else
  # /releases/latest skips pre-releases; take the newest entry instead.
  release_json="$(curl -fsSL "${api}?per_page=1" 2>&1)" || fail "Could not look up the latest release on GitHub (${release_json}). Try again in a few minutes, or download the DMG from https://github.com/${REPO}/releases"
fi
# `grep` exits 1 on no match; keep set -e from killing the script before the messages below.
tag="$(printf '%s' "$release_json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
[[ -n "$tag" ]] || fail "No releases found at https://github.com/${REPO}/releases"
urls="$(printf '%s' "$release_json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
sha_url="$(printf '%s\n' "$urls" | grep '\.dmg\.sha256$' | head -1 || true)"
[[ -n "$sha_url" ]] || fail "Release ${tag} has no .sha256 asset; is the build still running? https://github.com/${REPO}/releases/tag/${tag}"
dmg="$(basename "${sha_url%.sha256}")"
part_urls="$(printf '%s\n' "$urls" | grep "^.*/${dmg}\.part-" | sort || true)"
whole_url="$(printf '%s\n' "$urls" | grep "/${dmg}$" | head -1 || true)"
[[ -n "$part_urls" || -n "$whole_url" ]] || fail "Release ${tag} has no DMG assets."

mkdir -p "$CACHE"
cd "$CACHE"
say "Installing BellowFlow ${tag}"
curl -fsSL "$sha_url" -o "${dmg}.sha256"

if [[ -f "$dmg" ]] && shasum -a 256 -c "${dmg}.sha256" >/dev/null 2>&1; then
  say "Using the already-downloaded ${dmg}"
else
  rm -f "$dmg"
  if [[ -n "$whole_url" ]]; then
    say "Downloading ${dmg}"
    curl -fL --retry 3 -C - --progress-bar "$whole_url" -o "$dmg.partial"
    mv "$dmg.partial" "$dmg"
  else
    n=0
    for url in $part_urls; do
      n=$((n + 1)); part="$(basename "$url")"
      say "Downloading part ${n} ($(printf '%s\n' "$part_urls" | wc -l | tr -d ' ') total): ${part}"
      curl -fL --retry 3 -C - --progress-bar "$url" -o "$part"
    done
    say "Reassembling ${dmg}"
    cat "${dmg}".part-* > "$dmg"
  fi
  say "Verifying checksum"
  shasum -a 256 -c "${dmg}.sha256" || { rm -f "$dmg" "${dmg}".part-*; fail "Checksum mismatch; the download was corrupt. Run the installer again."; }
  rm -f "${dmg}".part-*
fi

say "Copying BellowFlow to ${DEST}"
mount="$(mktemp -d /tmp/bellowflow-dmg.XXXXXX)"
hdiutil attach "$dmg" -mountpoint "$mount" -nobrowse -quiet
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true' EXIT
app="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$app" ]] || fail "No .app found inside ${dmg}."
if pgrep -xq BellowFlow; then
  say "Quitting the running BellowFlow"
  osascript -e 'tell application "BellowFlow" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf "${DEST}/BellowFlow.app"
ditto "$app" "${DEST}/BellowFlow.app"
hdiutil detach "$mount" -quiet
trap - EXIT
# A notarized build passes Gatekeeper as is. An ad-hoc signed release candidate would be
# blocked until allowed in System Settings > Privacy & Security, so clear its quarantine flag.
if spctl --assess --type execute "${DEST}/BellowFlow.app" >/dev/null 2>&1; then
  say "Notarized by Apple; Gatekeeper accepts it"
else
  say "Development build (not notarized); clearing the quarantine flag"
  xattr -dr com.apple.quarantine "${DEST}/BellowFlow.app" 2>/dev/null || true
fi
rm -f "$dmg" "${dmg}.sha256"

say "Installed ${DEST}/BellowFlow.app (${tag})"
echo
echo "Opening BellowFlow. Grant Microphone and Accessibility in the setup window and click Start."
echo "The first start downloads the speech and cleanup models (about 5.3 GB, once)."
echo "When the status reads \"Ready\", press Control+Option+X to dictate."
open "${DEST}/BellowFlow.app"
