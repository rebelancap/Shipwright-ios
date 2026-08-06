#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/Shipwright"
BUILD="$ROOT/oracle/build-cmake"

[[ -d "$VENDOR/.git" ]] || { echo "FATAL: vendor/Shipwright missing — run scripts/bootstrap.sh" >&2; exit 1; }
[[ "${1:-}" == "--clean" ]] && rm -rf "$BUILD"

cmake -S "$VENDOR" -B "$BUILD" -GNinja -DCMAKE_BUILD_TYPE:STRING=Release
cmake --build "$BUILD" --target GenerateSohOtr
cmake --build "$BUILD"

BIN="$BUILD/soh/soh-macos"
[[ -x "$BIN" ]] || { echo "FATAL: expected oracle binary at $BIN" >&2; exit 1; }
echo "oracle built: $BIN"
