#!/bin/sh
# Builds the native module the package ships, kernel/vm (native/vm.zig),
# into lib/<platform>/vm.{dylib,so}. Run it after changing native/vm.zig.
#
#   tool/build.sh                          this machine's platform
#   tool/build.sh aarch64-linux x86_64-macos ...   zig target triples
#   tool/build.sh x86_64-windows-gnu       Windows: links slang.lib, so
#                                          `make windows` in slang first
#                                          (the JIT is arm64-only: the
#                                          interpreter runs the kernels)
set -e
cd "$(dirname "$0")/../native"
ZIG=${ZIG:-zig}
if [ $# -eq 0 ]; then
  "$ZIG" build --prefix .. --release
else
  for t in "$@"; do
    "$ZIG" build --prefix .. --release -Dtarget="$t"
  done
fi
