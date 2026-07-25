#!/bin/bash
# One command: pristine vendor -> overlay -> visionOS DEVICE app build (signed).
# Produces build-visionos/soh/Release-xros/soh.app
# Phase 1 of the Vision Pro port (VISION-PRO-GUIDE.md). The iOS build
# (build-ios.sh / build-ios/) is untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-visionos"
PREFIX="$ROOT/work/vision-deps/prefix"
SOH_O2R="$ROOT/oracle/build-cmake/soh/soh.o2r"
TEAM="${SOH_IOS_TEAM:?set your Apple Developer team id (see README)}"

[[ -d "$ROOT/vendor/Shipwright/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libopusfile.a" ]] || SOH_IOS_SDK=visionos "$ROOT/scripts/build-audio-deps-ios.sh"
[[ -f "$SOH_O2R" ]] || "$ROOT/scripts/build-oracle.sh"

# TARGETED_DEVICE_FAMILY=7 (Vision Pro); STRIP_INSTALLED_PRODUCT=NO — archive-
# time stripping removes dlsym'd symbols and kills OTA builds that work over
# cable (VISION-PRO-GUIDE 1.4 #1). Cache-level Xcode attributes override the
# per-target 0004 values.
# Port versioning (D-039) + remote console gate (D-040).
SOH_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SOH_BUILD="$(date -u +%Y%m%d%H%M)"
# Remote console: ON by default (OTA test builds are the common case);
# turned OFF for the rare GitHub release via SOH_REMOTE_CONSOLE=OFF.
CONSOLE="${SOH_REMOTE_CONSOLE:-ON}"
echo "=== soh visionOS $SOH_VERSION (build $SOH_BUILD), remote console: $CONSOLE ==="

cmake --no-warn-unused-cli -S "$ROOT/vendor/Shipwright" -B "$BUILD" -GXcode \
    "-DSOH_IOS_VERSION=$SOH_VERSION" "-DSOH_IOS_BUILD=$SOH_BUILD" \
    "-DSOH_REMOTE_CONSOLE=$CONSOLE" \
    -DCMAKE_SYSTEM_NAME=visionOS -DPLATFORM=VISIONOS \
    -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 -DCMAKE_BUILD_TYPE:STRING=Release \
    -DSOH_VISIONOS=1 \
    -DCMAKE_XCODE_ATTRIBUTE_XROS_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY=7 \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SOH_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    -DSOH_IOS_BUNDLE_IDENTIFIER=com.rebelancap.soh \
    "-DSOH_IOS_DEVELOPMENT_TEAM=$TEAM" \
    "-DPNG_LIBRARY=$PREFIX/lib/libpng16.a" \
    "-DPNG_PNG_INCLUDE_DIR=$PREFIX/include"

cmake --build "$BUILD" --config Release --target soh --parallel 12 -- -allowProvisioningUpdates

APP="$BUILD/soh/Release-xros/soh.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | sed -n '1,3p'
echo "built (visionOS device): $APP"
