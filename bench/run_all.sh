#!/bin/sh
# Runs every benchmark: the slang ones with bin/slang, the Lua ports with
# lua5.4 and luajit when they are installed, and the C sawtooth when cc is.
cd "$(dirname "$0")/.."
for b in bench/*.slang; do
  echo "== $b"
  bin/slang run "$b"
done
for lua in lua5.4 luajit "luajit -joff"; do
  if command -v ${lua%% *} >/dev/null 2>&1; then
    echo "== $lua"
    for b in bench/lua/*.lua; do
      $lua "$b"
    done
    $lua bench/lua/tables.lua shared
  fi
done
if command -v cc >/dev/null 2>&1; then
  echo "== bench/saw.c"
  cc -O2 -o /tmp/slang-saw bench/saw.c && /tmp/slang-saw
fi
