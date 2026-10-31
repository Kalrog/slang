#!/bin/sh
# Builds the native library the package ships: Jolt Physics and joltc (its
# C API) as one shared library, lib/<platform>/libjoltc.{dylib,so}, and
# include/joltc.h. The sources are pinned and checked; run it again only to
# move to new versions (change the pins) or to add a platform.
#
#   tool/build.sh                         this machine's platform
#   tool/build.sh linux-x86_64 macos-x86_64 ...
#
# Platforms: macos-aarch64, macos-x86_64 (on a Mac, with Xcode's tools),
# linux-x86_64, linux-aarch64 (cross-compiled by zig c++; ZIG names zig).
# Needs cmake and ninja. x86_64 builds target SSE4.2, without AVX, so they
# run on any x86_64 CPU of the last 15 years.
set -e
cd "$(dirname "$0")/.."
PKG=$(pwd)
CACHE=$PKG/tool/.cache
ZIG=${ZIG:-zig}
mkdir -p "$CACHE"

JOLT_VERSION=5.6.0
JOLT_SHA=6e069ee0172478cc78182047aac87e5310ba14a67a53348ae14cc37801fd3f8e
JOLTC_COMMIT=2bbcf73b1bec261e0351814662922f1b4784454c
JOLTC_SHA=c3bd5ccd336b18a547290b5028a355e8aca80e725a8785ae0fdaae014f6701cc

fetch() { # url file sha
  if [ ! -f "$2" ]; then curl -sL -o "$2.part" "$1" && mv "$2.part" "$2"; fi
  echo "$3  $2" | shasum -a 256 -c - > /dev/null || { echo "checksum mismatch: $2"; rm -f "$2"; exit 1; }
}

JOLT=$CACHE/JoltPhysics-$JOLT_VERSION
JOLTC=$CACHE/joltc-$JOLTC_COMMIT
if [ ! -d "$JOLT" ]; then
  fetch "https://github.com/jrouwe/JoltPhysics/archive/refs/tags/v$JOLT_VERSION.tar.gz" "$CACHE/jolt.tar.gz" $JOLT_SHA
  mkdir -p "$JOLT" && tar xzf "$CACHE/jolt.tar.gz" -C "$JOLT" --strip-components=1
fi
if [ ! -d "$JOLTC" ]; then
  fetch "https://github.com/amerkoleci/joltc/archive/$JOLTC_COMMIT.tar.gz" "$CACHE/joltc.tar.gz" $JOLTC_SHA
  mkdir -p "$JOLTC" && tar xzf "$CACHE/joltc.tar.gz" -C "$JOLTC" --strip-components=1
fi

host() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo macos-aarch64 ;;
    Darwin-x86_64) echo macos-x86_64 ;;
    Linux-x86_64) echo linux-x86_64 ;;
    Linux-aarch64) echo linux-aarch64 ;;
    *) echo "unknown platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
}

# a compiler wrapper for cmake: zig cc/c++ for a target
wrapper() { # file tool target
  printf '#!/bin/sh\nexec "%s" %s -target %s "$@"\n' "$ZIG" "$2" "$3" > "$1"
  chmod +x "$1"
}

build() { # platform
  P=$1
  OUT=$CACHE/build-$P
  FLAGS=""
  case $P in
    macos-aarch64) FLAGS="-DCMAKE_OSX_ARCHITECTURES=arm64" ;;
    macos-x86_64) FLAGS="-DCMAKE_OSX_ARCHITECTURES=x86_64" ;;
    linux-x86_64|linux-aarch64)
      ARCH=${P#linux-}
      TARGET=$ARCH-linux-gnu.2.28
      mkdir -p "$OUT"
      wrapper "$OUT/cc" cc $TARGET
      wrapper "$OUT/c++" c++ $TARGET
      printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$OUT/ar"
      printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$OUT/ranlib"
      chmod +x "$OUT/ar" "$OUT/ranlib"
      FLAGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$ARCH \
        -DCMAKE_C_COMPILER=$OUT/cc -DCMAKE_CXX_COMPILER=$OUT/c++ \
        -DCMAKE_AR=$OUT/ar -DCMAKE_RANLIB=$OUT/ranlib -DCMAKE_SHARED_LINKER_FLAGS=-s"
      ;;
    *) echo "unknown platform: $P" >&2; exit 1 ;;
  esac
  case $P in
    *x86_64) FLAGS="$FLAGS -DUSE_AVX=OFF -DUSE_AVX2=OFF -DUSE_AVX512=OFF \
      -DUSE_LZCNT=OFF -DUSE_TZCNT=OFF -DUSE_F16C=OFF -DUSE_FMADD=OFF" ;;
  esac
  echo "building $P"
  # shellcheck disable=SC2086
  cmake -S "$JOLTC" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Distribution \
    -DJOLT_PHYSICS_ROOT="$JOLT" -DJPH_BUILD_SHARED=ON -DJPH_SAMPLES=OFF \
    -DJPH_TESTS=OFF -DJPH_INSTALL=OFF -DJPH_USE_DX12=OFF -DJPH_USE_VK=OFF \
    -DJPH_USE_MTL=OFF -DJPH_USE_CPU_COMPUTE=OFF \
    -DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF \
    -DDEBUG_RENDERER_IN_DISTRIBUTION=OFF -DPROFILER_IN_DEBUG_AND_RELEASE=OFF \
    -DENABLE_OBJECT_STREAM=OFF $FLAGS > "$OUT.log" 2>&1 \
    || { tail -20 "$OUT.log"; exit 1; }
  ninja -C "$OUT" joltc >> "$OUT.log" 2>&1 || { tail -20 "$OUT.log"; exit 1; }
  mkdir -p "$PKG/lib/$P"
  case $P in
    macos-*) cp "$OUT/lib/libjoltc.dylib" "$PKG/lib/$P/libjoltc.dylib" ;;
    linux-*) cp "$OUT/lib/libjoltc.so" "$PKG/lib/$P/libjoltc.so" ;;
  esac
  echo "  lib/$P/$(ls "$PKG/lib/$P")"
}

[ $# -eq 0 ] && set -- "$(host)"
for p in "$@"; do build "$p"; done
cp "$JOLTC/include/joltc.h" "$PKG/include/joltc.h"
printf 'Jolt Physics %s, joltc %s\n' "$JOLT_VERSION" "$JOLTC_COMMIT" > "$PKG/lib/VERSION"
