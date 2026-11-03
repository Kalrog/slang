#!/bin/sh
# Builds the native module the package ships, midi/native (native/midi.c),
# into lib/<platform>/native.{dylib,so}. Run it after changing midi.c.
#
#   tool/build.sh                  this machine's platform (macOS: needs the
#                                  Xcode command line tools for CoreMIDI)
set -e
cd "$(dirname "$0")/../native"
ZIG=${ZIG:-zig}
"$ZIG" build --prefix .. --release "$@"
