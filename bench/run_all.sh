#!/bin/sh
# Runs every benchmark with the Go binary.
cd "$(dirname "$0")/.."
for b in bench/*.slang; do
  bin/slang run "$b"
done
