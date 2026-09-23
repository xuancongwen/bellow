#!/bin/bash
# Lists every crate compiled into the bundled VoxType binary (macOS arm64, Metal) with its
# license and repository, one per line: "name version|license|repository". Build
# dependencies are included since some ship generated code. Run from the pinned checkout.
set -euo pipefail
cd "${1:?voxtype checkout}"
cargo tree --locked --offline -p voxtype --target aarch64-apple-darwin --features gpu-metal -e normal,build --prefix none -f '{p}|{l}|{r}' \
  | sed 's/ (\*)$//; s/ (proc-macro)//; s/ (.*)|/|/' | grep -v '^voxtype ' | sort -u
