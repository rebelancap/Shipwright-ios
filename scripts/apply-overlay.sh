#!/bin/bash
# Apply the overlay patch series to vendor/Shipwright. Idempotent and loud:
# a patch that is neither applied nor cleanly appliable fails the build.
# Patch paths are relative to vendor/Shipwright (-p1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/Shipwright"
PATCHES="$ROOT/overlay/patches"

[[ -d "$VENDOR/.git" ]] || { echo "FATAL: vendor missing — run scripts/bootstrap.sh" >&2; exit 1; }

shopt -s nullglob
series=("$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch)
if [[ ${#series[@]} -eq 0 ]]; then
    echo "overlay: no patches"
    exit 0
fi

applied=0 skipped=0
for p in "${series[@]}"; do
    name="$(basename "$p")"
    # Forward dry-run first. --force on both probes: without it, patch
    # direction-guesses and exits 0 on the wrong direction (observed: an
    # unapplied patch passed the -R probe and was silently skipped).
    if patch -p1 --forward --force --fuzz=0 --dry-run -d "$VENDOR" < "$p" > /dev/null 2>&1; then
        patch -p1 --forward --force --fuzz=0 -d "$VENDOR" < "$p" > /dev/null
        echo "overlay: applied $name"
        applied=$((applied + 1))
    elif patch -p1 -R --force --fuzz=0 --dry-run -d "$VENDOR" < "$p" > /dev/null 2>&1; then
        skipped=$((skipped + 1))
    else
        echo "FATAL: overlay patch $name neither applied nor appliable" >&2
        exit 1
    fi
done
echo "overlay: $applied applied, $skipped already-applied, $((applied + skipped))/${#series[@]} total"
