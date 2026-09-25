#!/bin/bash
# Publishes the website by hand, without GitHub Actions: assembles site/ plus
# scripts/install.sh into a single-commit gh-pages branch and force-pushes it.
# GitHub Pages serves that branch (Settings -> Pages -> Deploy from a branch,
# gh-pages, /) at https://xuancongwen.github.io/bellow/. History lives on
# master, so the branch is rebuilt from scratch on every run.
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n scripts/install.sh
REMOTE="$(git remote get-url origin)"
SOURCE="$(git rev-parse --short HEAD)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R site/. "$STAGE/"
cp scripts/install.sh "$STAGE/install.sh"
touch "$STAGE/.nojekyll"   # serve files as they are; no Jekyll build
git -C "$STAGE" init -q -b gh-pages
git -C "$STAGE" add -A
git -C "$STAGE" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "Publish site from $SOURCE"
git -C "$STAGE" push --force --quiet "$REMOTE" gh-pages:gh-pages
echo "Published site from $SOURCE to gh-pages; Pages redeploys in about a minute."
