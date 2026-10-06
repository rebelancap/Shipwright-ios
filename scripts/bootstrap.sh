#!/bin/bash
set -euo pipefail

PIN="ecd889c2019b87e78b0a3d942a6a3fe98b7efaed" # tag 9.3.0 "Dewey Alpha", 2026-10-06
REPO="https://github.com/HarbourMasters/Shipwright.git"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/Shipwright"

if [[ ! -d "$VENDOR/.git" ]]; then
    git clone --recurse-submodules "$REPO" "$VENDOR"
fi
git -C "$VENDOR" fetch --tags origin
git -C "$VENDOR" checkout --detach "$PIN"
git -C "$VENDOR" submodule update --init --recursive

echo "vendor pinned: $(git -C "$VENDOR" rev-parse HEAD)"
echo "submodules:"
git -C "$VENDOR" submodule status
