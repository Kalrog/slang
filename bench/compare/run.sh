#!/bin/sh
# Runs the same benchmarks in slang and in other scripting languages and
# prints a table: the best of RUNS runs in ms (each program times itself,
# so start-up is not included), with x = time / slang time, and a geometric
# mean per language.
#
#   bench/compare/run.sh                 every benchmark, every language found
#   bench/compare/run.sh fib nbody       only these benchmarks
#   RUNS=5 bench/compare/run.sh          best of 5 (default 3)
#   LANGS="slang python lua" bench/compare/run.sh
#
# Languages (skipped when not installed): slang, python (python3), lua
# (lua5.4), luajit-interp (luajit -joff), luajit, node-interp
# (node --jitless), node, ruby, ruby-yjit (ruby --yjit). Every port checks
# its result; a result that differs from slang's is marked with "!".
cd "$(dirname "$0")"
root=../..
RUNS=${RUNS:-3}
LANGS=${LANGS:-"slang python lua luajit-interp luajit node-interp node ruby ruby-yjit"}
BENCHES=${*:-"fib sieve nbody objects strings hashmap dijkstra"}

# command and file for one language and benchmark
cmd() {
  case $1 in
    slang) echo "$root/bin/slang run slang/$2.slang" ;;
    python) echo "python3 python/$2.py" ;;
    lua) echo "lua5.4 lua/$2.lua" ;;
    luajit-interp) echo "luajit -joff lua/$2.lua" ;;
    luajit) echo "luajit lua/$2.lua" ;;
    node-interp) echo "node --jitless js/$2.js" ;;
    node) echo "node js/$2.js" ;;
    ruby) echo "ruby ruby/$2.rb" ;;
    ruby-yjit) echo "ruby --yjit ruby/$2.rb" ;;
  esac
}

have=""
for l in $LANGS; do
  exe=$(cmd "$l" fib)
  exe=${exe%% *}
  if command -v "$exe" >/dev/null 2>&1 || [ -x "$exe" ]; then
    have="$have $l"
  else
    echo "skipping $l: $exe not found" >&2
  fi
done

echo "versions:"
for l in $have; do
  case $l in
    slang) echo "  slang  $(git -C $root rev-parse --short HEAD 2>/dev/null)" ;;
    python) echo "  $(python3 --version 2>&1)" ;;
    lua) echo "  $(lua5.4 -v 2>&1 | cut -d' ' -f1-2)" ;;
    luajit) echo "  $(luajit -v 2>&1 | cut -d' ' -f1-2)" ;;
    node) echo "  node $(node --version)" ;;
    ruby) echo "  $(ruby --version | cut -d' ' -f1-2)" ;;
  esac
done
echo

results=$(mktemp)
trap 'rm -f "$results"' EXIT
for b in $BENCHES; do
  for l in $have; do
    best=""
    check=""
    r=0
    while [ $r -lt "$RUNS" ]; do
      out=$($(cmd "$l" "$b") 2>&1 | tail -n 1)
      ms=$(echo "$out" | sed -n 's/.* in \([0-9.]*\) ms.*/\1/p')
      if [ -z "$ms" ]; then
        echo "$l $b failed: $out" >&2
        break
      fi
      check=$(echo "$out" | sed -n 's/^[a-z]*: \(.*\) in .*/\1/p')
      if [ -z "$best" ]; then
        best=$ms
      else
        best=$(awk -v a="$best" -v b="$ms" 'BEGIN { print (b < a) ? b : a }')
      fi
      r=$((r + 1))
    done
    echo "$b $l ${best:-?} ${check:-?}" >> "$results"
    printf '.' >&2
  done
done
echo >&2

awk -v langs="$have" '
  BEGIN { n = split(langs, L, " ") }
  {
    ms[$1, $2] = $3; chk[$1, $2] = $4
    if (!($1 in seen)) { seen[$1] = 1; B[++nb] = $1 }
  }
  END {
    printf "%-10s", "ms"
    for (i = 1; i <= n; i++) printf " %15s", L[i]
    printf "\n"
    for (j = 1; j <= nb; j++) {
      b = B[j]; base = ms[b, "slang"]
      printf "%-10s", b
      for (i = 1; i <= n; i++) {
        l = L[i]; t = ms[b, l]
        if (t == "?") { printf " %15s", "failed"; continue }
        bad = (base != "" && chk[b, l] != chk[b, "slang"]) ? "!" : ""
        if (base != "" && base != "?" && l != "slang") {
          cell = sprintf("%.0f %5.2fx%s", t, t / base, bad)
          lg[l] += log(t / base); cnt[l]++
        } else cell = sprintf("%.0f%s", t, bad)
        printf " %15s", cell
      }
      printf "\n"
    }
    printf "%-10s", "geomean"
    for (i = 1; i <= n; i++) {
      l = L[i]
      if (l == "slang") printf " %15s", "1.00x"
      else if (cnt[l]) printf " %15s", sprintf("%.2fx", exp(lg[l] / cnt[l]))
      else printf " %15s", "-"
    }
    printf "\n\nx = time / slang time: above 1 means slower than slang, below 1 faster.\n"
  }
' "$results"
