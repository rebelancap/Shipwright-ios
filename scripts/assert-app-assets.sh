#!/bin/bash
# Post-build bundle check (Round 2 of the 9.3.0 fold-in, D-079).
# Upstream 9.3.0 ships the Torch yml tree as <app>/assets/{config.yml,<ver>/...}.
# Its POST_BUILD copy (copy_directory_if_different) never deletes, so an
# incremental build dir from the ZAPD era keeps assets/xml, Config_*.xml,
# filelists and TexturePool.xml in the .app — 54 MB of dead weight that would
# ship. Fail loudly if the yml tree is missing or any ZAPD leftover is present.
# Usage: assert-app-assets.sh <path/to/soh.app>
set -euo pipefail
APP="${1:?usage: assert-app-assets.sh <soh.app>}"
[[ -d "$APP" ]] || { echo "FATAL: no app at $APP" >&2; exit 1; }
fail=0
[[ -f "$APP/assets/config.yml" ]] || { echo "FATAL: $APP/assets/config.yml missing (Torch yml tree not copied)" >&2; fail=1; }
nver=$(find "$APP/assets" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
[[ "$nver" -ge 1 ]] || { echo "FATAL: no yml version dirs under $APP/assets" >&2; fail=1; }
for stale in assets/xml assets/filelists assets/symbols filelists TexturePool.xml assets/TexturePool.xml; do
    [[ ! -e "$APP/$stale" ]] || { echo "FATAL: ZAPD-era leftover in bundle: $APP/$stale (wipe the build dir)" >&2; fail=1; }
done
cfg=$(find "$APP" -maxdepth 2 -name 'Config_*.xml' | head -5)
[[ -z "$cfg" ]] || { echo "FATAL: ZAPD-era Config_*.xml in bundle:" >&2; echo "$cfg" >&2; fail=1; }
[[ $fail -eq 0 ]] || exit 1
echo "assets OK: $APP/assets (config.yml + $nver version dirs, no ZAPD leftovers)"
