#!/bin/sh
# Fetches the native library the package ships: wgpu-native (the WebGPU
# implementation of Firefox, in Rust, with the standard webgpu.h C API) as
# released prebuilt, lib/<platform>/libwgpu_native.{dylib,so}, and its
# headers include/webgpu.h and include/wgpu.h. The release is pinned and
# checked; run it again only to move to a new release (change the pins) or
# to add a platform. It also writes include/unimplemented.txt: the webgpu.h
# functions this release exports but does not implement (calling one ends
# the process), from the release's source; the package raises for those.
#
#   tool/fetch.sh                        this machine's platform
#   tool/fetch.sh linux-x86_64 ...       others
#
# Platforms: macos-aarch64, macos-x86_64, linux-x86_64, linux-aarch64,
# windows-x86_64 (the GNU toolchain's build: it needs no Visual C++
# runtime installed, only Windows' own DLLs).
set -e
cd "$(dirname "$0")/.."
PKG=$(pwd)
CACHE=$PKG/tool/.cache
mkdir -p "$CACHE"

WGPU_VERSION=v29.0.1.1
sha_of() {
  case $1 in
    macos-aarch64) echo a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e ;;
    macos-x86_64) echo 8e2f7378548ddd0e2cf21e7d864dda46e953f0af724855a33778b85ead206d41 ;;
    linux-x86_64) echo 95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a ;;
    linux-aarch64) echo 015fcdf1dbae82e614a783cc38017e5399ae0927a889fe9b69c9b664bc61b47a ;;
    windows-x86_64) echo d471e3614733c1d4ddd61bfd19868356477d0d37bf531bf8c6cb64a7f579bd2a ;;
    *) echo "unknown platform: $1" >&2; exit 1 ;;
  esac
}

host() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo macos-aarch64 ;;
    Darwin-x86_64) echo macos-x86_64 ;;
    Linux-x86_64) echo linux-x86_64 ;;
    Linux-aarch64) echo linux-aarch64 ;;
    *) echo "unknown platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
}

fetch() { # platform
  P=$1
  SHA=$(sha_of "$P")
  ZIP=$CACHE/wgpu-$WGPU_VERSION-$P.zip
  # (the release names Windows builds by toolchain)
  ASSET=$P
  [ "$P" = windows-x86_64 ] && ASSET=windows-x86_64-gnu
  if [ ! -f "$ZIP" ]; then
    curl -sL -o "$ZIP.part" "https://github.com/gfx-rs/wgpu-native/releases/download/$WGPU_VERSION/wgpu-$ASSET-release.zip"
    mv "$ZIP.part" "$ZIP"
  fi
  echo "$SHA  $ZIP" | shasum -a 256 -c - > /dev/null || { echo "checksum mismatch: $ZIP"; rm -f "$ZIP"; exit 1; }
  OUT=$CACHE/wgpu-$P
  rm -rf "$OUT" && mkdir -p "$OUT" && unzip -q -o "$ZIP" -d "$OUT"
  mkdir -p "$PKG/lib/$P"
  case $P in
    macos-*) cp "$OUT/lib/libwgpu_native.dylib" "$PKG/lib/$P/" ;;
    linux-*) cp "$OUT/lib/libwgpu_native.so" "$PKG/lib/$P/" ;;
    windows-*) cp "$OUT/lib/wgpu_native.dll" "$PKG/lib/$P/" ;;
  esac
  # (the Windows release's headers have CRLF line ends)
  for h in webgpu.h wgpu.h; do tr -d '\r' < "$OUT/include/webgpu/$h" > "$PKG/include/$h"; done
  echo "  lib/$P/$(ls "$PKG/lib/$P")"
}

[ $# -eq 0 ] && set -- "$(host)"
for p in "$@"; do fetch "$p"; done
SRC=$CACHE/unimplemented-$WGPU_VERSION.rs
if [ ! -f "$SRC" ]; then
  curl -sfL -o "$SRC.part" "https://raw.githubusercontent.com/gfx-rs/wgpu-native/$WGPU_VERSION/src/unimplemented.rs"
  mv "$SRC.part" "$SRC"
fi
grep -o 'fn wgpu[A-Za-z0-9]*' "$SRC" | sed 's/fn //' | sort > "$PKG/include/unimplemented.txt"
[ -s "$PKG/include/unimplemented.txt" ] || { echo "no unimplemented functions found in $SRC"; exit 1; }
echo "  include/unimplemented.txt ($(wc -l < "$PKG/include/unimplemented.txt" | tr -d ' ') functions)"
printf 'wgpu-native %s\n' "$WGPU_VERSION" > "$PKG/lib/VERSION"
