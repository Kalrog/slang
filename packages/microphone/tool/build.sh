#!/bin/sh
# Builds the native module the package ships, microphone/native
# (native/microphone.c), into lib/<platform>/native.{dylib,so}. Run it after
# changing microphone.c.
#
#   tool/build.sh                  this machine's platform (macOS: needs the
#                                  Xcode command line tools for CoreAudio)
set -e
cd "$(dirname "$0")/../native"
ZIG=${ZIG:-zig}
"$ZIG" build --prefix .. --release "$@"
