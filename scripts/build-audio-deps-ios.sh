#!/bin/bash
# Build static ogg/vorbis/opus/opusfile for iOS (device, arm64) into
# work/ios-deps/prefix. Predecessor pattern: deps built once, referenced as
# imported targets by the soh iOS CMake branch (overlay 0004).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# SOH_IOS_SDK=device (default) → iphoneos arm64, prefix work/ios-deps/prefix.
# SOH_IOS_SDK=simulator        → iphonesimulator arm64, prefix work/ios-sim-deps/prefix.
# SOH_IOS_SDK=visionsim        → xrsimulator arm64, prefix work/vision-sim-deps/prefix.
# SOH_IOS_SDK=visionos         → xros arm64, prefix work/vision-deps/prefix.
SDK="${SOH_IOS_SDK:-device}"
SYSNAME=iOS
DEPTGT=15.0
if [[ "$SDK" == "simulator" ]]; then
    WORK="$ROOT/work/ios-sim-deps"
    SYSROOT_FLAG=(-DCMAKE_OSX_SYSROOT=iphonesimulator)
elif [[ "$SDK" == "visionsim" ]]; then
    WORK="$ROOT/work/vision-sim-deps"
    SYSROOT_FLAG=(-DCMAKE_OSX_SYSROOT=xrsimulator)
    SYSNAME=visionOS
    DEPTGT=2.0
elif [[ "$SDK" == "visionos" ]]; then
    WORK="$ROOT/work/vision-deps"
    SYSROOT_FLAG=(-DCMAKE_OSX_SYSROOT=xros)
    SYSNAME=visionOS
    DEPTGT=2.0
else
    WORK="$ROOT/work/ios-deps"
    SYSROOT_FLAG=()
fi
PREFIX="$WORK/prefix"
SRC="$WORK/src"
IOS_FLAGS=(-DCMAKE_SYSTEM_NAME=$SYSNAME -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPTGT
           -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release
           "${SYSROOT_FLAG[@]}"
           -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$PREFIX"
           "-DCMAKE_PREFIX_PATH=$PREFIX"
           "-DCMAKE_FIND_ROOT_PATH=$PREFIX"
           -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
mkdir -p "$SRC" "$PREFIX"

fetch() { # name url tag
    if [[ ! -d "$SRC/$1" ]]; then
        git clone -q --depth 1 --branch "$3" "$2" "$SRC/$1"
    fi
}

BDIR="build-$SDK"
build() { # name extra-args...
    local name="$1"; shift
    echo "=== $name ($SDK) ==="
    cmake -S "$SRC/$name" -B "$SRC/$name/$BDIR" -GNinja "${IOS_FLAGS[@]}" "$@"
    cmake --build "$SRC/$name/$BDIR" --parallel
    cmake --install "$SRC/$name/$BDIR"
}

fetch ogg      https://github.com/xiph/ogg.git      v1.3.6
fetch vorbis   https://github.com/xiph/vorbis.git   v1.3.7
fetch opus     https://github.com/xiph/opus.git     v1.5.2
fetch libpng   https://github.com/pnggroup/libpng.git v1.6.50
# opusfile: CMake support postdates the last release (v0.12, 2020) — use
# master and record the resolved commit here after the first successful build.
# Resolved 2026-07-10: 3ecc22aa0a4430f61c2403d57370a089536d197a. Needs full
# clone + tags (CMake derives its version from git describe).
fetch opusfile https://github.com/xiph/opusfile.git master
if git -C "$SRC/opusfile" rev-parse --is-shallow-repository | grep -q true; then
    git -C "$SRC/opusfile" fetch -q --unshallow --tags
fi
git -C "$SRC/opusfile" checkout -q 3ecc22aa0a4430f61c2403d57370a089536d197a

build libpng   -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
build ogg      -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
build vorbis   "-DOGG_INCLUDE_DIR=$PREFIX/include" "-DOGG_LIBRARY=$PREFIX/lib/libogg.a"
build opus     -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
build opusfile -DOP_DISABLE_HTTP=ON -DOP_DISABLE_DOCS=ON -DOP_DISABLE_EXAMPLES=ON \
               "-DOGG_INCLUDE_DIR=$PREFIX/include" "-DOGG_LIBRARY=$PREFIX/lib/libogg.a" \
               "-DOPUS_INCLUDE_DIR=$PREFIX/include/opus" "-DOPUS_LIBRARY=$PREFIX/lib/libopus.a"

echo "=== verify ($SDK) ==="
# Assert the exact platform so a device slice can never sneak into a sim build
# (or vice-versa) — that mismatch only surfaces as a confusing app-link error.
# otool may print the platform as a name (IOS/IOSSIMULATOR) or its numeric
# code (2=IOS, 7=IOSSIMULATOR) depending on toolchain version — accept both.
case "$SDK" in
    simulator) WANT="IOSSIMULATOR|7" ;;
    visionos)  WANT="XROS|11" ;;
    visionsim) WANT="XROS_SIMULATOR|XROSSIMULATOR|12" ;;
    *)         WANT="IOS|2" ;;
esac
for lib in libogg libvorbis libvorbisfile libvorbisenc libopus libopusfile libpng16; do
    f="$PREFIX/lib/$lib.a"
    [[ -f "$f" ]] || { echo "FATAL: missing $f" >&2; exit 1; }
    lipo -info "$f" | grep -q arm64 || { echo "FATAL: $f not arm64" >&2; exit 1; }
    plat=$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
    [[ "$plat" =~ ^($WANT)$ ]] || { echo "FATAL: $f platform=$plat, expected $WANT" >&2; exit 1; }
done
echo "audio deps OK ($SDK): $PREFIX"
