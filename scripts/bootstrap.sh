#!/bin/bash
set -euo pipefail

PIN="417256b42c722a2a8dcb9627c3762f0072c78310" # develop, 9.2.3-245, 2026-07-10
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
