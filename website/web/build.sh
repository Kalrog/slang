#!/bin/sh
# The playground's graphics VM: slang built with Emscripten, with raylib's
# web platform and libffi, so that the raylib package runs in the browser as
# it is (`make wasm-gfx`). Writes website/public/slang-gfx.js and .wasm.
#
# Needs emcc (brew install emscripten) and ZIG. raylib and libffi are
# downloaded once (pinned versions, checked) into website/web/.cache.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
ZIG=${ZIG:-zig}
CACHE=$ROOT/website/web/.cache
OUT=$ROOT/website/public
mkdir -p "$CACHE" "$OUT"

RAYLIB_VERSION=5.5
RAYLIB_SHA=aea98ecf5bc5c5e0b789a76de0083a21a70457050ea4cc2aec7566935f5e258e
LIBFFI_VERSION=3.5.2
LIBFFI_SHA=f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc

fetch() { # url file sha
  if [ ! -f "$2" ]; then curl -sL -o "$2.part" "$1" && mv "$2.part" "$2"; fi
  echo "$3  $2" | shasum -a 256 -c - > /dev/null || { echo "checksum mismatch: $2"; rm -f "$2"; exit 1; }
}

# raylib, its web platform (GLFW and WebGL come from Emscripten)
RAYLIB=$CACHE/raylib-$RAYLIB_VERSION
if [ ! -f "$RAYLIB/web/libraylib.a" ]; then
  fetch "https://github.com/raysan5/raylib/archive/refs/tags/$RAYLIB_VERSION.tar.gz" "$CACHE/raylib.tar.gz" $RAYLIB_SHA
  rm -rf "$RAYLIB" && mkdir -p "$RAYLIB" && tar xzf "$CACHE/raylib.tar.gz" -C "$RAYLIB" --strip-components=1
  mkdir -p "$RAYLIB/web"
  for f in rcore rshapes rtextures rtext rmodels utils raudio; do
    emcc -c "$RAYLIB/src/$f.c" -o "$RAYLIB/web/$f.o" -Os -std=gnu99 -DPLATFORM_WEB \
      -DGRAPHICS_API_OPENGL_ES2 -D_GNU_SOURCE -Wno-deprecated-pragma -w
  done
  emar rcs "$RAYLIB/web/libraylib.a" "$RAYLIB"/web/*.o
fi

# libffi's Emscripten port (what Python's ctypes uses in the browser)
LIBFFI=$CACHE/libffi-$LIBFFI_VERSION
if [ ! -f "$LIBFFI/out/lib/libffi.a" ]; then
  fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" "$CACHE/libffi.tar.gz" $LIBFFI_SHA
  rm -rf "$LIBFFI" && mkdir -p "$LIBFFI" && tar xzf "$CACHE/libffi.tar.gz" -C "$LIBFFI" --strip-components=1
  (cd "$LIBFFI" && emconfigure ./configure --host=wasm32-unknown-emscripten --prefix="$LIBFFI/out" \
    --enable-static --disable-shared --disable-dependency-tracking --disable-builddir \
    --disable-multi-os-directory --disable-raw-api --disable-docs CFLAGS="-O2" > configure.log 2>&1 \
    && emmake make -j8 install > make.log 2>&1)
fi

# the VM, compiled by Zig for wasm32-emscripten
SYSROOT=$(em-config CACHE)/sysroot
(cd zig && "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall --sysroot "$SYSROOT" -p zig-out-em)

# the symbols slang/ffi finds: raylib's and raymath's functions
emnm -g --defined-only "$RAYLIB/web/libraylib.a" 2>/dev/null | awk 'NF>=3 && $2 ~ /[TD]/ {print $3}' | sort -u > "$CACHE/defined.txt"
bin/slang run website/web/symbols.slang "$CACHE/symbols.c" "$CACHE/defined.txt" "$RAYLIB/src/raylib.h" "$RAYLIB/src/raymath.h" > /dev/null
emcc -c "$CACHE/symbols.c" -o "$CACHE/symbols.o" -Os -I"$RAYLIB/src" -DPLATFORM_WEB
: > "$CACHE/empty"

# linked by Emscripten: the raylib package and raylib's headers go into the
# virtual file system, where the package looks for an installed raylib
# (HEAPF32: raylib's audio, miniaudio, reads samples through it)
emcc zig/zig-out-em/lib/slang.o "$CACHE/symbols.o" "$RAYLIB/web/libraylib.a" "$LIBFFI/out/lib/libffi.a" \
  -o "$OUT/slang-gfx.js" -O2 -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8MB \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSlang -sINVOKE_RUN=0 -sEXIT_RUNTIME=1 \
  -sENVIRONMENT=web -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=FS,callMain,HEAPF32 \
  -sEXPORTED_FUNCTIONS=_main,_emscripten_cancel_main_loop,_CloseWindow,_CloseAudioDevice \
  --embed-file "$RAYLIB/src/raylib.h@/usr/include/raylib.h" \
  --embed-file "$RAYLIB/src/raymath.h@/usr/include/raymath.h" \
  --embed-file "$CACHE/empty@/usr/lib/libraylib.so" \
  --embed-file "packages/raylib/init.slang@/raylib/init.slang" \
  --embed-file "packages/raylib/names.slang@/raylib/names.slang" \
  --embed-file "packages/raylib/slang.project@/raylib/slang.project"
echo "website/public/slang-gfx.js and slang-gfx.wasm"
