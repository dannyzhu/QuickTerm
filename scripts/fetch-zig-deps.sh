#!/usr/bin/env bash
# 预取 Ghostty 的全部 Zig 依赖到本地缓存（Zig 自带 HTTP 客户端不走代理时的离线通道）。
# 依赖清单来源：vendor/ghostty/build.zig.zon 的 .url 字段 ∪ build.zig.zon.txt（官方离线打包清单）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
[ -x "$ZIG" ] || { echo "error: 先运行 scripts/build-ghosttykit.sh 安装 Zig"; exit 1; }

DEPS="$TOOLS/zig-deps"
mkdir -p "$DEPS"

# zon 里若有 git+ 依赖需要单独处理；先报出来
if grep -q '\.url = "git+' "$GHOSTTY/build.zig.zon"; then
  echo "warning: build.zig.zon 含 git+ 依赖，需要人工处理："
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
# 传递依赖中的 git+https 引用（Zig git 客户端不走代理）：改用 GitHub codeload tarball。
# 目前已知：vaxis → uucode@5f05f8f8（同 commit tarball 的包哈希与 git 拉取一致）
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
echo "OK: 依赖已全部灌入 Zig 缓存"
