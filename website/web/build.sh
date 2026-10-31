#!/bin/sh
# The playground's graphics VM: slang built with Emscripten, with raylib's
# web platform, Box2D, Jolt Physics (with joltc) and libffi, so that the
# raylib, box2d and jolt packages run in the browser as they are (`make
# wasm-gfx`). Writes website/public/slang-gfx.js and .wasm.
#
# Needs emcc (brew install emscripten), cmake, ninja and ZIG. The libraries
# are downloaded once (pinned versions, checked) into website/web/.cache.
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
BOX2D_VERSION=3.2.0
BOX2D_SHA=ffec747b27a2267016f8d0240d658c82d187fb2271fa0f69fcbe53fbc067180d
# the versions packages/jolt/tool/build.sh builds
JOLT_VERSION=5.6.0
JOLT_SHA=6e069ee0172478cc78182047aac87e5310ba14a67a53348ae14cc37801fd3f8e
JOLTC_COMMIT=2bbcf73b1bec261e0351814662922f1b4784454c
JOLTC_SHA=c3bd5ccd336b18a547290b5028a355e8aca80e725a8785ae0fdaae014f6701cc

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

# Box2D, with its own CMake (scalar math: no wasm SIMD needed)
BOX2D=$CACHE/box2d-$BOX2D_VERSION
if [ ! -f "$BOX2D/web/src/libbox2d.a" ]; then
  fetch "https://github.com/erincatto/box2d/archive/refs/tags/v$BOX2D_VERSION.tar.gz" "$CACHE/box2d.tar.gz" $BOX2D_SHA
  rm -rf "$BOX2D" && mkdir -p "$BOX2D" && tar xzf "$CACHE/box2d.tar.gz" -C "$BOX2D" --strip-components=1
  emcmake cmake -S "$BOX2D" -B "$BOX2D/web" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DBOX2D_SAMPLES=OFF -DBOX2D_UNIT_TESTS=OFF -DBOX2D_BENCHMARKS=OFF -DBOX2D_DOCS=OFF \
    -DBOX2D_VALIDATE=OFF -DBOX2D_DISABLE_SIMD=ON > "$BOX2D/web.log" 2>&1
  ninja -C "$BOX2D/web" box2d >> "$BOX2D/web.log" 2>&1
fi

# Jolt Physics and joltc, with joltc's CMake. A page has no threads (that
# would need cross-origin isolation): joltc takes 0 threads to mean as many
# as there are cores, so here it means none, and jobs run on the caller.
JOLT=$CACHE/JoltPhysics-$JOLT_VERSION
JOLTC=$CACHE/joltc-$JOLTC_COMMIT
if [ ! -f "$JOLTC/web/lib/libjoltc.a" ]; then
  fetch "https://github.com/jrouwe/JoltPhysics/archive/refs/tags/v$JOLT_VERSION.tar.gz" "$CACHE/jolt.tar.gz" $JOLT_SHA
  fetch "https://github.com/amerkoleci/joltc/archive/$JOLTC_COMMIT.tar.gz" "$CACHE/joltc.tar.gz" $JOLTC_SHA
  rm -rf "$JOLT" "$JOLTC" && mkdir -p "$JOLT" "$JOLTC"
  tar xzf "$CACHE/jolt.tar.gz" -C "$JOLT" --strip-components=1
  tar xzf "$CACHE/joltc.tar.gz" -C "$JOLTC" --strip-components=1
  sed -i '' 's/createConfig.numThreads : -1;/createConfig.numThreads : 0;/' "$JOLTC/src/joltc.cpp"
  grep -q 'createConfig.numThreads : 0;' "$JOLTC/src/joltc.cpp" || { echo "joltc: thread count not patched"; exit 1; }
  emcmake cmake -S "$JOLTC" -B "$JOLTC/web" -G Ninja -DCMAKE_BUILD_TYPE=Distribution \
    -DJOLT_PHYSICS_ROOT="$JOLT" -DJPH_SAMPLES=OFF -DJPH_TESTS=OFF -DJPH_INSTALL=OFF \
    -DJPH_USE_DX12=OFF -DJPH_USE_VK=OFF -DJPH_USE_MTL=OFF -DJPH_USE_CPU_COMPUTE=OFF \
    -DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF -DDEBUG_RENDERER_IN_DISTRIBUTION=OFF \
    -DPROFILER_IN_DEBUG_AND_RELEASE=OFF -DENABLE_OBJECT_STREAM=OFF > "$JOLTC/web.log" 2>&1
  ninja -C "$JOLTC/web" joltc >> "$JOLTC/web.log" 2>&1
fi

# the VM, compiled by Zig for wasm32-emscripten
SYSROOT=$(em-config CACHE)/sysroot
(cd zig && "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall --sysroot "$SYSROOT" -p zig-out-em)

# the symbols slang/ffi finds: the functions of raylib, raymath, Box2D and
# joltc
JOLT_LIBS="$JOLTC/web/lib/libjoltc.a $JOLTC/web/lib/libJolt.a"
emnm -g --defined-only "$RAYLIB/web/libraylib.a" "$BOX2D/web/src/libbox2d.a" $JOLT_LIBS 2>/dev/null \
  | awk 'NF>=3 && $2 ~ /[TD]/ {print $3}' | sort -u > "$CACHE/defined.txt"
bin/slang run website/web/symbols.slang "$CACHE/symbols.c" "$CACHE/defined.txt" \
  "$RAYLIB/src/raylib.h" "$RAYLIB/src/raymath.h" "$BOX2D"/include/box2d/*.h "$JOLTC/include/joltc.h" > /dev/null
emcc -c "$CACHE/symbols.c" -o "$CACHE/symbols.o" -Os -I"$RAYLIB/src" -DPLATFORM_WEB
: > "$CACHE/empty"

# linked by Emscripten (em++: Jolt is C++): the packages and the libraries'
# headers go into the virtual file system, where the packages look for
# installed libraries (HEAPF32: raylib's audio, miniaudio, reads samples
# through it)
em++ zig/zig-out-em/lib/slang.o "$CACHE/symbols.o" "$RAYLIB/web/libraylib.a" \
  "$BOX2D/web/src/libbox2d.a" $JOLT_LIBS "$LIBFFI/out/lib/libffi.a" \
  -o "$OUT/slang-gfx.js" -O2 -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8MB \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSlang -sINVOKE_RUN=0 -sEXIT_RUNTIME=1 \
  -sENVIRONMENT=web -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=FS,callMain,HEAPF32 \
  -sEXPORTED_FUNCTIONS=_main,_emscripten_cancel_main_loop,_CloseWindow,_CloseAudioDevice \
  --embed-file "$RAYLIB/src/raylib.h@/usr/include/raylib.h" \
  --embed-file "$RAYLIB/src/raymath.h@/usr/include/raymath.h" \
  --embed-file "$CACHE/empty@/usr/lib/libraylib.so" \
  --embed-file "packages/raylib/init.slang@/raylib/init.slang" \
  --embed-file "packages/raylib/names.slang@/raylib/names.slang" \
  --embed-file "packages/raylib/slang.project@/raylib/slang.project" \
  --embed-file "$BOX2D/include/box2d@/usr/include/box2d" \
  --embed-file "$CACHE/empty@/usr/lib/libbox2d.so" \
  --embed-file "packages/box2d/init.slang@/box2d/init.slang" \
  --embed-file "packages/box2d/names.slang@/box2d/names.slang" \
  --embed-file "packages/box2d/slang.project@/box2d/slang.project" \
  --embed-file "$JOLTC/include/joltc.h@/usr/include/joltc.h" \
  --embed-file "$CACHE/empty@/usr/lib/libjoltc.so" \
  --embed-file "packages/jolt/init.slang@/jolt/init.slang" \
  --embed-file "packages/jolt/names.slang@/jolt/names.slang" \
  --embed-file "packages/jolt/slang.project@/jolt/slang.project"
echo "website/public/slang-gfx.js and slang-gfx.wasm"
