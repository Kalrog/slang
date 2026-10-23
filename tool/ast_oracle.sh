#!/bin/sh
# Compares the AST produced by the legacy Dart parser (legacy/tool/stage0.dart --ast) with
# the AST produced by the self-hosted parser running on the Go VM, for every
# given file (default: test/*.slang and extension sources).
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FILES="$@"
if [ -z "$FILES" ]; then
  FILES="$(ls test/*.slang slang/lib/*.slang slang/compiler/*.slang extensions/*.slang)"
fi
OUT=${TMPDIR:-/tmp}/slang-ast-oracle
mkdir -p "$OUT"
fail=0
for f in $FILES; do
  if grep -qE '^[[:space:]]*extension[[:space:]]*("|\{)' "$f"; then
    echo "skip  $f (uses extension statements, unknown to the legacy parser)"
    continue
  fi
  name=$(echo "$f" | tr '/' '_')
  # the Dart tool must run inside legacy/ so that its packages resolve
  (cd legacy && dart run tool/stage0.dart --ast "$ROOT/$f") > "$OUT/$name.dart" 2>&1 || true
  bin/slang run tool/ast_dump.slang "$f" > "$OUT/$name.go" 2>&1 || true
  if diff -q "$OUT/$name.dart" "$OUT/$name.go" > /dev/null; then
    echo "ok    $f"
  else
    echo "DIFF  $f   (diff $OUT/$name.dart $OUT/$name.go)"
    fail=1
  fi
done
exit $fail
