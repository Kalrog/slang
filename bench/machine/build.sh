#!/bin/sh
# Builds what bench/machine/run.slang compares slang against, for one
# platform, with zig cc at -O2: native (bench/machine/native.c) and Lua 5.4.7
# (from its pinned release: the same interpreter, built the same way, on
# every machine). Into bench/machine/bin/<platform>/.
#
#   bench/machine/build.sh                      this machine
#   bench/machine/build.sh x86_64-windows-gnu   Windows (the test kit does)
#
# ZIG names zig 0.17 (default: zig). The Lua source is fetched once into
# bench/machine/.cache and checked against its hash.
set -e
cd "$(dirname "$0")"
here=$(pwd)
ZIG=${ZIG:-zig}
# (zig runs in slang's zig/, whose build.zig.zon names its version: what
# anyzig and the like go by)
zcc() { (cd "$here/../../zig" && "$ZIG" cc "$@"); }
TARGET=${1:-}
LUA_VERSION=5.4.7
LUA_SHA256=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30

# the platform's folder: as slang names platforms (os.platform())
case "$TARGET" in
  "") os=$(uname -s | tr 'A-Z' 'a-z'); arch=$(uname -m)
      [ "$os" = darwin ] && os=macos
      [ "$arch" = arm64 ] && arch=aarch64
      platform="$os-$arch"; target_flag="" ;;
  x86_64-windows*) platform=windows-x86_64; target_flag="-target $TARGET" ;;
  x86_64-linux*) platform=linux-x86_64; target_flag="-target $TARGET" ;;
  aarch64-linux*) platform=linux-aarch64; target_flag="-target $TARGET" ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac
exe=""
case "$platform" in windows-*) exe=".exe" ;; esac
out="$here/bin/$platform"
mkdir -p "$out" .cache

echo "native ($platform)"
# shellcheck disable=SC2086
zcc $target_flag -O2 -s -o "$out/native$exe" "$here/native.c"

tarball=".cache/lua-$LUA_VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  curl -fsSL "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" -o "$tarball.part"
  mv "$tarball.part" "$tarball"
fi
sum=$(shasum -a 256 "$tarball" 2>/dev/null || sha256sum "$tarball")
if [ "${sum%% *}" != "$LUA_SHA256" ]; then
  echo "lua-$LUA_VERSION.tar.gz: wrong SHA-256 (${sum%% *})" >&2
  rm -f "$tarball"
  exit 1
fi
src="$here/.cache/lua-$LUA_VERSION/src"
[ -d "$src" ] || tar -xzf "$tarball" -C .cache
echo "lua $LUA_VERSION ($platform)"
defines=""
case "$platform" in
  macos-*) defines="-DLUA_USE_MACOSX" ;;
  linux-*) defines="-DLUA_USE_LINUX" ;;
esac
files=""
for f in "$src"/*.c; do
  case "$(basename "$f")" in luac.c) ;; *) files="$files $f" ;; esac
done
# shellcheck disable=SC2086
zcc $target_flag -O2 -s -std=gnu99 $defines -o "$out/lua$exe" $files -lm
# (zig's debug symbols for Windows: not needed to run)
rm -f "$out"/*.pdb
echo "into $out"
