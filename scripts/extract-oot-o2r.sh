#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROM="${1:-$ROOT/work/gamedata/oot-usa.z64}"
OUTDIR="${2:-$ROOT/oracle/shiphome}"
TORCH="$ROOT/oracle/build-cmake/soh-torch"
ASSETS="$ROOT/oracle/build-cmake/soh/assets"
PORTVER="$(sed -n 's/^project(Ship VERSION \([0-9.]*\) .*/\1/p' "$ROOT/vendor/Shipwright/CMakeLists.txt")"

[[ -x "$TORCH" ]] || { echo "FATAL: soh-torch not built at $TORCH (scripts/build-oracle.sh builds it)" >&2; exit 1; }
[[ -f "$ROM" ]] || { echo "FATAL: ROM not found at $ROM" >&2; exit 1; }
[[ -f "$ASSETS/config.yml" && -d "$ASSETS/pal_gc_dbg" ]] || { echo "FATAL: extractor yml tree missing at $ASSETS" >&2; exit 1; }
[[ -n "$PORTVER" ]] || { echo "FATAL: could not read the port version from the root CMakeLists.txt" >&2; exit 1; }

mkdir -p "$OUTDIR"
TMP="$(mktemp -d /tmp/soh-extract.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

T0=$(date +%s)
if ! /usr/bin/time -l "$TORCH" --src "$ASSETS" --dest "$TMP" --version "$PORTVER" "$ROM" 2> "$TMP/time.txt"; then
    cat "$TMP/time.txt" >&2
    echo "FATAL: soh-torch failed" >&2
    exit 1
fi
T1=$(date +%s)
grep -E "maximum resident set size| real " "$TMP/time.txt" || echo "(no /usr/bin/time stats)"

[[ -s "$TMP/oot.o2r" ]] || { echo "FATAL: extraction produced no oot.o2r" >&2; ls -la "$TMP" >&2; exit 1; }
cp "$TMP/oot.o2r" "$OUTDIR/oot.o2r"
ls -la "$OUTDIR/oot.o2r"
echo "extracted OK in $((T1 - T0)) s (port version $PORTVER): $OUTDIR/oot.o2r"
