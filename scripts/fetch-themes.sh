#!/usr/bin/env bash
# 从 omarchy 官方仓库同步主题资产（MIT）：
#   colors.toml（进 git）+ 每主题第 1 张背景图（不进 git，构建期打入 bundle）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 https://github.com/basecamp/omarchy "$TMP/omarchy"

for dir in "$TMP/omarchy/themes"/*/; do
  name="$(basename "$dir")"
  mkdir -p "$ROOT/Themes/$name/backgrounds"
  cp "$dir/colors.toml" "$ROOT/Themes/$name/"
  bg="$(ls "$dir/backgrounds/" 2>/dev/null | sort | head -1 || true)"
  if [ -n "$bg" ]; then
    cp "$dir/backgrounds/$bg" "$ROOT/Themes/$name/backgrounds/"
  fi
done
echo "OK: $(ls "$ROOT/Themes" | wc -l | tr -d ' ') 个主题已同步到 Themes/"
