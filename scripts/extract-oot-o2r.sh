#!/bin/bash
# Generate oot.o2r from the user's ROM with the standalone ZAPD binary,
# replicating soh's in-app Extractor::CallZapd argv exactly
# (soh/soh/Extractor/Extract.cpp:641-702). Our ROM is PAL GC Debug (non-MQ)
# → version GC_NMQ_D → oot.o2r. Usage: extract-oot-o2r.sh [rom] [outdir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROM="${1:-$ROOT/work/gamedata/oot-usa.z64}"
OUTDIR="${2:-$ROOT/oracle/shiphome}"
ZAPD="$ROOT/oracle/build-cmake/ZAPD/ZAPD.out"
# The merged extractor layout (Config_*.xml + filelists + xml/) is assembled by
# the build next to the soh binary (soh/CMakeLists.txt:611-612) — same layout
# the shipped app carries at GetAppBundlePath()/assets.
ASSETS="$ROOT/oracle/build-cmake/soh/assets"
VERSION="GC_NMQ_D"
PORTVER="9.2.3"

[[ -x "$ZAPD" ]] || { echo "FATAL: ZAPD not built at $ZAPD" >&2; exit 1; }
[[ -f "$ROM" ]] || { echo "FATAL: ROM not found at $ROM" >&2; exit 1; }
[[ -d "$ASSETS/xml/$VERSION" && -f "$ASSETS/Config_$VERSION.xml" ]] || { echo "FATAL: extractor assets missing $ASSETS/xml/$VERSION" >&2; exit 1; }

ROM="$(cd "$(dirname "$ROM")" && pwd)/$(basename "$ROM")"
mkdir -p "$OUTDIR"

TMP="$(mktemp -d /tmp/soh-extract.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ln -s "$ASSETS" "$TMP/assets"

(cd "$TMP" && "$ZAPD" ed \
    -i "assets/xml/$VERSION" \
    -b "$ROM" \
    -fl assets/filelists \
    -gsf 0 \
    -rconf "assets/Config_$VERSION.xml" \
    -se OTR \
    --otrfile oot.o2r \
    --portVer "$PORTVER" \
    -o placeholder -osf placeholder)

[[ -s "$TMP/oot.o2r" ]] || { echo "FATAL: extraction produced no oot.o2r" >&2; exit 1; }
cp "$TMP/oot.o2r" "$OUTDIR/oot.o2r"
ls -la "$OUTDIR/oot.o2r"
echo "extracted OK: $OUTDIR/oot.o2r"
