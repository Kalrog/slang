#!/bin/sh
# Refreshes the deploy repo of Switchback's daily run (vps/switchback, a
# git repo of its own next to this checkout by default) from this
# checkout: the site (make switchback-web), the server's files, and the
# source of slang's VM, which the box compiles in Docker. Review, commit
# and `git push server main` there to deploy.
#
#   make switchback-release [DEST=../vps/switchback]
#
# Everything comes from the working tree (slang's source: the files git
# tracks or would track, so no build output). SLANG_VERSION says which
# commit, and whether the tree had changes.
set -e
cd "$(dirname "$0")/../../.."
DEST=${1:-../vps/switchback}
if [ ! -d "$DEST/.git" ]; then
  echo "no git repo at $DEST (git init it: see its README after the first release, or ../vps/switchback/README.md)" >&2
  exit 1
fi
DEST=$(cd "$DEST" && pwd)

echo "==> the site"
make switchback-web
rm -rf "$DEST/app/site" "$DEST/app/server"
mkdir -p "$DEST/app/site" "$DEST/app/server"
cp -R examples/switchback/web/. "$DEST/app/site/"
cp examples/switchback/server/*.slang "$DEST/app/server/"

echo "==> slang's source"
rm -rf "$DEST/slang"
mkdir -p "$DEST/slang"
git ls-files -z --cached --others --exclude-standard -- zig boot extensions/native |
  tar --null -T - -cf - | tar -x -C "$DEST/slang"

dirty=""
if [ -n "$(git status --porcelain --untracked-files=no -- zig boot extensions/native examples/switchback packages website/web)" ]; then
  dirty=" (with uncommitted changes)"
fi
echo "slang $(git rev-parse --short HEAD)$dirty, $(date -u +%Y-%m-%dT%H:%MZ)" > "$DEST/SLANG_VERSION"

echo "==> $DEST: $(cat "$DEST/SLANG_VERSION")"
git -C "$DEST" status --short | head -20
echo "commit and 'git push server main' in $DEST to deploy"
