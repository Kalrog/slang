#!/bin/sh
# Builds the native library the package ships: SDL3 as a shared library,
# lib/<platform>/libSDL3.{dylib,so}. The source is pinned and checked; run
# it again only to move to a new SDL version (change the pin) or to add a
# platform. include/window.h, the declarations the package reads, is kept
# by hand (SDL's own headers are too much macro for slang/ffi, and
# SDL_Event is a union): check it against the new headers when the pin
# moves.
#
#   tool/build.sh                       this machine's platform
#   tool/build.sh macos-x86_64 ...      others this machine can build
#
# Platforms: macos-aarch64, macos-x86_64 (on a Mac, with Xcode's tools),
# linux-x86_64, linux-aarch64 (on Linux of that architecture, with the X11
# and Wayland development packages SDL's README-linux lists). Needs cmake
# and ninja.
set -e
cd "$(dirname "$0")/.."
PKG=$(pwd)
CACHE=$PKG/tool/.cache
mkdir -p "$CACHE"

SDL_VERSION=3.4.20
SDL_SHA=f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f

fetch() { # url file sha
  if [ ! -f "$2" ]; then curl -sL -o "$2.part" "$1" && mv "$2.part" "$2"; fi
  echo "$3  $2" | shasum -a 256 -c - > /dev/null || { echo "checksum mismatch: $2"; rm -f "$2"; exit 1; }
}

SDL=$CACHE/SDL3-$SDL_VERSION
if [ ! -d "$SDL" ]; then
  fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL3-$SDL_VERSION.tar.gz" "$CACHE/sdl.tar.gz" $SDL_SHA
  mkdir -p "$SDL" && tar xzf "$CACHE/sdl.tar.gz" -C "$SDL" --strip-components=1
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

build() { # platform
  P=$1
  OUT=$CACHE/build-$P
  case $P in
    macos-aarch64) FLAGS="-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" ;;
    macos-x86_64) FLAGS="-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" ;;
    linux-*)
      [ "$P" = "$(host)" ] || { echo "$P builds on $P only" >&2; exit 1; }
      FLAGS="" ;;
    *) echo "unknown platform: $P" >&2; exit 1 ;;
  esac
  echo "building $P"
  # shellcheck disable=SC2086
  cmake -S "$SDL" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_TEST_LIBRARY=OFF $FLAGS > "$OUT.log" 2>&1 \
    || { tail -20 "$OUT.log"; exit 1; }
  ninja -C "$OUT" >> "$OUT.log" 2>&1 || { tail -20 "$OUT.log"; exit 1; }
  mkdir -p "$PKG/lib/$P"
  case $P in
    macos-*) cp "$OUT/libSDL3.0.dylib" "$PKG/lib/$P/libSDL3.dylib" ;;
    linux-*) cp "$OUT/libSDL3.so.0" "$PKG/lib/$P/libSDL3.so" && strip "$PKG/lib/$P/libSDL3.so" ;;
  esac
  echo "  lib/$P/$(ls "$PKG/lib/$P")"
}

[ $# -eq 0 ] && set -- "$(host)"
for p in "$@"; do build "$p"; done
printf 'SDL %s\n' "$SDL_VERSION" > "$PKG/lib/VERSION"
