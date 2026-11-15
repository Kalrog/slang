#!/bin/sh
# The playground's graphics VM: slang built with Emscripten, with raylib's
# web platform (on WebGL 2), Box2D, Jolt Physics (with joltc), libffi and
# the kernel package's interpreter, so that the raylib, box2d, jolt, kernel
# and dsp packages run in the browser as they are (`make wasm-gfx`). Writes
# website/public/slang-gfx.js and .wasm.
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

# raylib, its web platform (GLFW and WebGL come from Emscripten), on
# OpenGL ES 3 (WebGL 2): desktop GLSL 330 then runs as GLSL ES 3.00 (the
# raylib package rewrites the #version), and GLSL 100 still runs
RAYLIB=$CACHE/raylib-$RAYLIB_VERSION
if [ ! -f "$RAYLIB/web-es3/libraylib.a" ]; then
  if [ ! -f "$RAYLIB/src/raylib.h" ]; then
    fetch "https://github.com/raysan5/raylib/archive/refs/tags/$RAYLIB_VERSION.tar.gz" "$CACHE/raylib.tar.gz" $RAYLIB_SHA
    rm -rf "$RAYLIB" && mkdir -p "$RAYLIB" && tar xzf "$CACHE/raylib.tar.gz" -C "$RAYLIB" --strip-components=1
  fi
  mkdir -p "$RAYLIB/web-es3"
  for f in rcore rshapes rtextures rtext rmodels utils raudio; do
    emcc -c "$RAYLIB/src/$f.c" -o "$RAYLIB/web-es3/$f.o" -Os -std=gnu99 -DPLATFORM_WEB \
      -DGRAPHICS_API_OPENGL_ES3 -D_GNU_SOURCE -Wno-deprecated-pragma -w
  done
  emar rcs "$RAYLIB/web-es3/libraylib.a" "$RAYLIB"/web-es3/*.o
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
(cd zig && "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast --sysroot "$SYSROOT" -p zig-out-em)

# the kernel package's interpreter and JIT (packages/kernel/native; in the
# browser the JIT makes WebAssembly, see native/wasm.zig), linked in: the VM knows it as a built-in extension, which a
# constructor registers before main (the package's lib/emscripten-wasm32/
# vm.so in the file system is a placeholder that makes the package look for
# it)
(cd packages/kernel/native && "$ZIG" build -Dtarget=wasm32-emscripten --release \
  -Dlibc-include="$SYSROOT/include" --sysroot "$SYSROOT" --prefix "$CACHE/kernel")
cat > "$CACHE/linked.c" <<'EOF2'
typedef int (*version_fn)(void);
typedef int (*open_fn)(void *);
void slang_register_extension(const char *name, version_fn version, open_fn open);
int slang_ext_version_kernel_vm(void);
int slang_open_kernel_vm(void *);
__attribute__((constructor)) static void linked_extensions(void) {
  slang_register_extension("kernel_vm", slang_ext_version_kernel_vm, slang_open_kernel_vm);
}
EOF2
emcc -c "$CACHE/linked.c" -o "$CACHE/linked.o" -Os
# its JIT's browser half (native/web.c: kernels compiled to WebAssembly);
# the modules it makes import libm's functions from the VM
emcc -c packages/kernel/native/web.c -o "$CACHE/kernel_web.o" -Os
# slang/web's messages between a program and its page
emcc -c website/web/bridge.c -o "$CACHE/bridge.o" -Os
LIBM=_sin,_cos,_tan,_asin,_acos,_atan,_exp,_exp2,_log,_log2,_tanh,_sinh,_cosh,_round,_pow,_atan2

# the symbols slang/ffi finds: the functions of raylib, raymath, rlgl, Box2D and
# joltc
JOLT_LIBS="$JOLTC/web/lib/libjoltc.a $JOLTC/web/lib/libJolt.a"
emnm -g --defined-only "$RAYLIB/web-es3/libraylib.a" "$BOX2D/web/src/libbox2d.a" $JOLT_LIBS 2>/dev/null \
  | awk 'NF>=3 && $2 ~ /[TD]/ {print $3}' | sort -u > "$CACHE/defined.txt"
bin/slang run website/web/symbols.slang "$CACHE/symbols.c" "$CACHE/defined.txt" \
  "$RAYLIB/src/raylib.h" "$RAYLIB/src/raymath.h" "$RAYLIB/src/rlgl.h" "$BOX2D"/include/box2d/*.h "$JOLTC/include/joltc.h" > /dev/null
emcc -c "$CACHE/symbols.c" -o "$CACHE/symbols.o" -Os -I"$RAYLIB/src" -DPLATFORM_WEB
: > "$CACHE/empty"

# the kernel and dsp packages' sources, at /kernel and /dsp
KERNEL_FILES="--embed-file $CACHE/empty@/kernel/lib/emscripten-wasm32/vm.so"
for f in slang.project init.slang compiler.slang file.slang grammar.slang lower.slang syntax.slang; do
  KERNEL_FILES="$KERNEL_FILES --embed-file packages/kernel/$f@/kernel/$f"
done
DSP_FILES=""
for f in slang.project slang.lock init.slang build.slang codegen.slang eval.slang file.slang \
  grammar.slang runtime.slang signal.slang wav.slang std.dsp; do
  DSP_FILES="$DSP_FILES --embed-file packages/dsp/$f@/dsp/$f"
done

# linked by Emscripten (em++: Jolt is C++): the packages and the libraries'
# headers go into the virtual file system, where the packages look for
# installed libraries (HEAPF32: raylib's audio, miniaudio, reads samples
# through it; a callback is a function libffi adds to the table)
em++ zig/zig-out-em/lib/slang.o "$CACHE/symbols.o" "$CACHE/kernel/lib/kernel_vm.o" "$CACHE/linked.o" "$CACHE/kernel_web.o" "$CACHE/bridge.o" "$RAYLIB/web-es3/libraylib.a" \
  "$BOX2D/web/src/libbox2d.a" $JOLT_LIBS "$LIBFFI/out/lib/libffi.a" \
  -o "$OUT/slang-gfx.js" -O2 --profiling-funcs -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH=1 -sALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=8MB \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSlang -sINVOKE_RUN=0 -sEXIT_RUNTIME=1 \
  -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 \
  -sENVIRONMENT=web -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=FS,callMain,HEAPF32,ENV,IDBFS -lidbfs.js \
  -sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE='$stringToNewUTF8,$UTF8ToString'  \
  -sEXPORTED_FUNCTIONS=_main,_emscripten_cancel_main_loop,_CloseWindow,_CloseAudioDevice,$LIBM \
  --embed-file "$RAYLIB/src/raylib.h@/usr/include/raylib.h" \
  --embed-file "$RAYLIB/src/raymath.h@/usr/include/raymath.h" \
  --embed-file "$CACHE/empty@/usr/lib/libraylib.so" \
  --embed-file "packages/raylib/init.slang@/raylib/init.slang" \
  --embed-file "packages/raylib/names.slang@/raylib/names.slang" \
  --embed-file "packages/raylib/stream.slang@/raylib/stream.slang" \
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
  --embed-file "packages/jolt/slang.project@/jolt/slang.project" \
  $KERNEL_FILES $DSP_FILES
echo "website/public/slang-gfx.js and slang-gfx.wasm"
