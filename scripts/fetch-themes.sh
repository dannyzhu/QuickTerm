#!/usr/bin/env bash
# Sync theme assets from the official omarchy repository (MIT):
#   colors.toml (checked into git) + all per-theme backgrounds (not in git, bundled at build time).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 https://github.com/basecamp/omarchy "$TMP/omarchy"

for dir in "$TMP/omarchy/themes"/*/; do
  name="$(basename "$dir")"
  mkdir -p "$ROOT/Themes/$name/backgrounds"
  cp "$dir/colors.toml" "$ROOT/Themes/$name/"
  # All background images (selectable in the background panel; not in git, bundled at build time)
  if [ -d "$dir/backgrounds" ]; then
    cp "$dir/backgrounds/"* "$ROOT/Themes/$name/backgrounds/" 2>/dev/null || true
  fi
done
echo "OK: $(ls "$ROOT/Themes" | wc -l | tr -d ' ') themes synced to Themes/"
