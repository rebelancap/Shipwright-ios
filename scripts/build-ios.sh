#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-ios"
PREFIX="$ROOT/work/ios-deps/prefix"
SOH_O2R="$ROOT/oracle/build-cmake/soh/soh.o2r"
TEAM="${SOH_IOS_TEAM:?set your Apple Developer team id (see README)}"

[[ -d "$ROOT/vendor/Shipwright/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libopusfile.a" ]] || "$ROOT/scripts/build-audio-deps-ios.sh"
if [[ ! -f "$SOH_O2R" ]]; then
    echo "soh.o2r missing — building host oracle first (produces it)"
    "$ROOT/scripts/build-oracle.sh"
fi

SOH_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SOH_BUILD="$(date -u +%Y%m%d%H%M)"
CONSOLE="${SOH_REMOTE_CONSOLE:-ON}"
echo "=== soh $SOH_VERSION (build $SOH_BUILD), remote console: $CONSOLE ==="

cmake --no-warn-unused-cli -S "$ROOT/vendor/Shipwright" -B "$BUILD" -GXcode \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    "-DSOH_IOS_VERSION=$SOH_VERSION" "-DSOH_IOS_BUILD=$SOH_BUILD" \
    "-DSOH_REMOTE_CONSOLE=$CONSOLE" \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SOH_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    -DSOH_IOS_BUNDLE_IDENTIFIER=com.rebelancap.soh \
    "-DSOH_IOS_DEVELOPMENT_TEAM=$TEAM" \
    "-DPNG_LIBRARY=$PREFIX/lib/libpng16.a" \
    "-DPNG_PNG_INCLUDE_DIR=$PREFIX/include"

cmake --build "$BUILD" --config Release --target soh --parallel 12 -- -allowProvisioningUpdates

APP="$BUILD/soh/Release-iphoneos/soh.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | sed -n '1,3p'
echo "built: $APP"
