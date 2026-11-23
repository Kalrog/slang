#!/bin/sh
# Makes the Windows test kit: one folder (and zip) with slang for Windows,
# its tests, the packages' Windows libraries and, when ../model_coder is
# there, the game; a tester runs check.cmd and sends windows_report.txt
# back (tool/windows/check.slang). Cross-compiles on macOS or Linux.
#
#   tool/windows/kit.sh [out_dir]     (default dist/windows-kit)
#
#   <out>/check.cmd        runs every check, writes windows_report.txt
#   <out>/play.cmd         starts the game
#   <out>/README.txt       what to do, for the tester
#   <out>/slang/           bin (slang.exe, slang.dll), lib (extensions),
#                          the tests, packages (Windows libraries only)
#   <out>/model_coder/     the game, with lib/windows-x86_64/opus.dll
#   <out>.zip
#
# ZIG names zig 0.17 (default: zig).
set -e
cd "$(dirname "$0")/../.."
SLANG=$(pwd)
ZIG=${ZIG:-zig}
OUT=${1:-$SLANG/dist/windows-kit}
GAME=$SLANG/../model_coder

echo "building slang for Windows"
(cd zig && "$ZIG" build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p zig-out-windows)
WIN=$SLANG/zig/zig-out-windows

rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/slang"

# the files of a git work tree (tracked, and new ones not ignored) that
# pass a filter, copied with their paths: copy_tree <src> <dest> <grep -v
# pattern>
copy_tree() {
  (cd "$1" && git ls-files -z --cached --others --exclude-standard \
    | tr '\0' '\n' | grep -Ev "$3" | while IFS= read -r f; do
      [ -f "$f" ] && printf '%s\0' "$f"
    done | tar --null -T - -cf -) | (cd "$2" && tar -xf -)
}

echo "copying slang"
# not the website, editors, docs, benchmarks or other platforms' libraries
copy_tree "$SLANG" "$OUT/slang" \
  '^(website|editors|doc|bench|scratch|takes|plans|dist)/|^packages/[^/]+/lib/(macos|linux)-'
mkdir -p "$OUT/slang/bin" "$OUT/slang/lib"
cp "$WIN/bin/slang.exe" "$WIN/bin/slang.dll" "$OUT/slang/bin/"
cp "$WIN"/lib/*.dll "$WIN/lib/slang.lib" "$OUT/slang/lib/"

if [ -d "$GAME" ]; then
  echo "building opus for Windows (model_coder/tools/opus)"
  (cd "$GAME/tools/opus" && "$ZIG" build --prefix ../.. -Dtarget=x86_64-windows-gnu)
  echo "copying the game"
  mkdir -p "$OUT/model_coder"
  copy_tree "$GAME" "$OUT/model_coder" '^(build|export|dist)/|^lib/(macos|linux)-'
fi

cat > "$OUT/check.cmd" <<'EOF'
@echo off
rem Runs every check and writes windows_report.txt (and burrower_shot.png).
cd /d "%~dp0"
slang\bin\slang.exe run slang\tool\windows\check.slang %*
echo.
echo Done. Please send back windows_report.txt and burrower_shot.png.
pause
EOF

cat > "$OUT/play.cmd" <<'EOF'
@echo off
rem Starts the game. To play together on one network: one player runs
rem play.cmd, the other play.cmd --join <the first player's IP address>.
cd /d "%~dp0model_coder"
..\slang\bin\slang.exe run game\burrower.slang %*
if errorlevel 1 pause
EOF

cat > "$OUT/README.txt" <<'EOF'
Thanks for testing! This folder is a game written in slang, built for
Windows on a Mac. Nothing here installs anything or needs admin rights.

1. Unzip the folder anywhere (not inside "Program Files").

2. Double-click check.cmd. It runs every automatic check (a few minutes;
   windows may flash and close, a test sound plays at volume 0). If
   Windows asks whether to allow network access, allow it (the
   multiplayer test talks to itself).
   If it seems stuck on one line for more than five minutes, close the
   window: the report so far is saved.

3. Send back:
   - windows_report.txt
   - burrower_shot.png (if it was made)

4. If you have a few more minutes: double-click play.cmd and play for
   two minutes. Notes on anything that seems wrong help a lot:
   - does the window open, how smooth is it (choppy, stutters)?
   - mouse and keyboard: does everything respond?
   - sound: do you hear the machine and the surroundings?
   - two computers on one network: one runs play.cmd, the other
     play.cmd --join <the first one's IP address>
   If something fails, the black window shows the error: a screenshot
   of it helps.

"Windows protected your PC" (SmartScreen) can appear because the program
is not signed: "More info", then "Run anyway".
EOF

echo "zipping"
(cd "$(dirname "$OUT")" && rm -f "$(basename "$OUT").zip" && zip -qr "$(basename "$OUT").zip" "$(basename "$OUT")")
du -sh "$OUT" "$OUT.zip"
