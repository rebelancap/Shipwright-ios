#!/bin/bash
# Boot the iPhone Air simulator, install the sim build, seed oot.o2r into its
# data container, launch, and capture a screenshot.
# Usage: run-sim.sh [shot-name]   (default: sim-boot)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/spikes/soh-sim-build/soh/Release-iphonesimulator/soh.app"
BUNDLE_ID="com.harbourmasters.soh"
OOT="$ROOT/oracle/shiphome/oot.o2r"
SHOT="${1:-sim-boot}"

[[ -d "$APP" ]] || { echo "FATAL: no sim app at $APP — run scripts/build-sim.sh" >&2; exit 1; }
[[ -f "$OOT" ]] || { echo "FATAL: no oot.o2r — run scripts/extract-oot-o2r.sh" >&2; exit 1; }

# Pick (the first) iPhone Air simulator, else any iPhone 17-family device.
UDID=$(xcrun simctl list devices available 2>/dev/null | grep -m1 "iPhone Air" | grep -oE '[0-9A-F-]{36}' || true)
[[ -n "$UDID" ]] || UDID=$(xcrun simctl list devices available 2>/dev/null | grep -m1 "iPhone 17" | grep -oE '[0-9A-F-]{36}')
echo "simulator udid: $UDID"

xcrun simctl bootstatus "$UDID" -b   # boots if needed, waits until ready
xcrun simctl install "$UDID" "$APP"

# Seed the ROM archive into the app's Documents (container exists post-install).
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
mkdir -p "$CONTAINER/Documents"
cp "$OOT" "$CONTAINER/Documents/oot.o2r"
echo "seeded oot.o2r into $CONTAINER/Documents"

xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
echo "launched $BUNDLE_ID on sim; waiting for first scene…"

# Give the engine time to extract-check, boot, and reach the attract scene.
for _ in $(seq 1 12); do
    xcrun simctl spawn "$UDID" log show --last 30s 2>/dev/null | grep -q "Scene Init" && break
    sleep 5
done

mkdir -p "$ROOT/artifacts"
xcrun simctl io "$UDID" screenshot "$ROOT/artifacts/$SHOT.png"
echo "captured artifacts/$SHOT.png"
sips -g pixelWidth -g pixelHeight "$ROOT/artifacts/$SHOT.png" 2>/dev/null | tail -2 || true

# Also grab the engine log (SOH_PERF lines etc.) from the sim's data container.
# NOTE: simulator perf is NOT authoritative — it runs on the Mac's GPU, not the
# A19. The screenshot (render correctness + drawable pixel size) is the prize.
LOGDIR="$CONTAINER/Documents/logs"
if [[ -d "$LOGDIR" ]]; then
    cp -R "$LOGDIR" "$ROOT/artifacts/$SHOT-logs"
    echo "--- SOH_PERF (simulator, non-authoritative) ---"
    grep -h "SOH_PERF" "$ROOT/artifacts/$SHOT-logs"/* 2>/dev/null | tail -3 || echo "(no perf lines yet)"
fi
