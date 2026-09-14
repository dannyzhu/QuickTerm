#!/usr/bin/env bash
# Prefetch all of Ghostty's Zig dependencies into the local cache (the offline path for when Zig's
# built-in HTTP client does not go through the proxy).
# Dependency list: the .url fields of vendor/ghostty/build.zig.zon ∪ build.zig.zon.txt (the
# official offline packaging list).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
[ -x "$ZIG" ] || { echo "error: run scripts/build-ghosttykit.sh first to install Zig"; exit 1; }

DEPS="$TOOLS/zig-deps"
mkdir -p "$DEPS"

# git+ dependencies in the zon need manual handling; report them up front
if grep -q '\.url = "git+' "$GHOSTTY/build.zig.zon"; then
  echo "warning: build.zig.zon has git+ dependencies that need manual handling:"
  sed -n 's/.*\.url = "\(git+[^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon"
fi

{ sed -n 's/.*\.url = "\(https[^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon"
  grep '^https' "$GHOSTTY/build.zig.zon.txt" 2>/dev/null || true
} | sort -u | while read -r url; do
  f="$DEPS/$(basename "$url")"
  if [ ! -f "$f" ]; then
    echo "download: $url"
    curl -fL --retry 3 "$url" -o "$f"
  fi
  "$ZIG" fetch "$f" > /dev/null
  echo "fetched:  $(basename "$url")"
done
# git+https references in transitive dependencies (Zig's git client ignores the proxy): use the
# GitHub codeload tarball instead.
# Known so far: vaxis → uucode@5f05f8f8 (the tarball of that commit has the same package hash as
# the git fetch)
GIT_DEPS="jacobsandlund/uucode#5f05f8f83a75caea201f12cc8ea32a2d82ea9732"
for dep in $GIT_DEPS; do
  repo="${dep%%#*}"; commit="${dep##*#}"
  f="$DEPS/$(basename "$repo")-$commit.tar.gz"
  if [ ! -f "$f" ]; then
    echo "download: https://github.com/$repo/archive/$commit.tar.gz"
    curl -fL --retry 3 "https://github.com/$repo/archive/$commit.tar.gz" -o "$f"
  fi
  "$ZIG" fetch "$f" > /dev/null
  echo "fetched:  $(basename "$f")"
done
echo "OK: all dependencies loaded into the Zig cache"
