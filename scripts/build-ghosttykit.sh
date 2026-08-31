#!/usr/bin/env bash
# 构建 GhosttyKit.xcframework。Zig 版本严格跟随 vendor/ghostty 的 pin。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
OUT="$GHOSTTY/macos/GhosttyKit.xcframework"

ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
[ -n "$ZIG_VERSION" ] || { echo "error: 无法从 build.zig.zon 解析 Zig 版本"; exit 1; }

case "$(uname -m)" in
  arm64) ZARCH=aarch64 ;;
  *)     ZARCH=x86_64  ;;
esac

ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG" ]; then
  mkdir -p "$TOOLS"
  # 0.14.1 起命名为 zig-<arch>-macos-<ver>，更早为 zig-macos-<arch>-<ver>；两种都试
  for NAME in "zig-$ZARCH-macos-$ZIG_VERSION" "zig-macos-$ZARCH-$ZIG_VERSION"; do
    URL="https://ziglang.org/download/$ZIG_VERSION/$NAME.tar.xz"
    echo "尝试下载 $URL"
    if curl -fL "$URL" -o "$TOOLS/zig.tar.xz"; then
      tar -xJf "$TOOLS/zig.tar.xz" -C "$TOOLS"
      mv "$TOOLS/$NAME" "$TOOLS/zig-$ZIG_VERSION"
      rm "$TOOLS/zig.tar.xz"
      break
    fi
  done
  [ -x "$ZIG" ] || { echo "error: Zig $ZIG_VERSION 下载失败"; exit 1; }
fi
echo "using zig: $("$ZIG" version)"

cd "$GHOSTTY"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native

test -d "$OUT" || { echo "error: 未找到 $OUT"; exit 1; }
echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty （打包进 app bundle）"
