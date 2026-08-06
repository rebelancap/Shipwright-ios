#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/spikes/soh-sim-build"
PREFIX="$ROOT/work/ios-sim-deps/prefix"
SOH_O2R="$ROOT/oracle/build-cmake/soh/soh.o2r"

[[ -d "$ROOT/vendor/Shipwright/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libopusfile.a" ]] || SOH_IOS_SDK=simulator "$ROOT/scripts/build-audio-deps-ios.sh"
[[ -f "$SOH_O2R" ]] || "$ROOT/scripts/build-oracle.sh"

SOH_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SOH_BUILD="$(date -u +%Y%m%d%H%M)"
CONSOLE="${SOH_REMOTE_CONSOLE:-ON}"
echo "=== soh sim $SOH_VERSION (build $SOH_BUILD), remote console: $CONSOLE ==="

cmake --no-warn-unused-cli -S "$ROOT/vendor/Shipwright" -B "$BUILD" -GXcode \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    "-DSOH_IOS_VERSION=$SOH_VERSION" "-DSOH_IOS_BUILD=$SOH_BUILD" \
    "-DSOH_REMOTE_CONSOLE=$CONSOLE" \
    -DCMAKE_SYSTEM_NAME=iOS -DPLATFORM=SIMULATORARM64 \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SOH_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    "-DPNG_LIBRARY=$PREFIX/lib/libpng16.a" \
    "-DPNG_PNG_INCLUDE_DIR=$PREFIX/include"

cmake --build "$BUILD" --config Release --target soh --parallel 12

APP="$BUILD/soh/Release-iphonesimulator/soh.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
lipo -info "$APP/soh"
echo "built (simulator): $APP"
