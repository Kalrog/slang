#!/bin/sh
# Compares the bytecode produced by the legacy Dart compiler (stage 0) with the
# bytecode produced by the self-hosted compiler for every given file, by
# diffing their disassembly.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FILES="$@"
if [ -z "$FILES" ]; then
  FILES="$(ls test/*.slang slang/lib/*.slang slang/compiler/*.slang)"
fi
OUT=${TMPDIR:-/tmp}/slang-bytecode-oracle
rm -rf "$OUT"; mkdir -p "$OUT/dart" "$OUT/go"
# the Dart tool must run inside legacy/ so that its packages resolve; origins
# are made relative again with --strip
ABS=""
for f in $FILES; do ABS="$ABS $ROOT/$f"; done
(cd legacy && dart run tool/stage0.dart --out "$OUT/dart" --strip "$ROOT/" $ABS) 2>/dev/null
fail=0
for f in $FILES; do
  base=$(echo "$f" | sed 's/\.slang$//')
  name=$(echo "$base" | tr '/' '_')
  bin/slang compile "$f" -o "$OUT/go/$name.slb" 2> "$OUT/go/$name.err" || true
  bin/slang disasm "$OUT/dart/$base.slb" > "$OUT/$name.dart.txt" 2>&1 || true
  bin/slang disasm "$OUT/go/$name.slb" > "$OUT/$name.go.txt" 2>&1 || true
  if diff -q "$OUT/$name.dart.txt" "$OUT/$name.go.txt" > /dev/null; then
    echo "ok    $f"
  else
    echo "DIFF  $f   (diff $OUT/$name.dart.txt $OUT/$name.go.txt)"
    fail=1
  fi
done
exit $fail
