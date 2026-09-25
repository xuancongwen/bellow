#!/bin/bash
# Local stand-in for the CI build job: release build, Python tests, Swift tests, shell syntax.
# About 30 seconds with a warm .build. `git push` runs it through scripts/hooks/pre-push once
# `git config core.hooksPath scripts/hooks` has been set for the clone; `git push --no-verify`
# skips it for one push.
set -euo pipefail
cd "$(dirname "$0")/.."
step() { printf '\n== %s\n' "$*"; }
step 'bash -n scripts/*.sh'
bash -n scripts/*.sh scripts/hooks/*
step 'swift build -c release'
swift build -c release
step 'python3 -m unittest discover -s tests'
python3 -m unittest discover -s tests -v
step 'swift test'
# Drop the per-case "started"/"passed" chatter; failures, errors, and the suite totals stay.
swift test 2>&1 | grep -vE "^Test Case '.*' (started|passed)"
printf '\nAll checks passed.\n'
