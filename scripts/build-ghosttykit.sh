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

# --- SDK overlay：Xcode 26.x SDK 的 tbd 主文档缺 arm64-macos target，
# --- Zig 0.15 链接器不做 arm64→arm64e 回退，导致全部符号 undefined。
# --- 做一个符号链接 overlay，仅拷贝并修补 usr/lib 的 tbd；用 xcrun shim 指向它。
SDK="$(/usr/bin/xcrun --show-sdk-path)"
OV="$TOOLS/sdk-arm64fix"
if [ ! -f "$OV/usr/lib/libSystem.tbd" ] || ! grep -q 'arm64-macos' "$OV/usr/lib/libSystem.tbd"; then
  rm -rf "$OV"; mkdir -p "$OV/usr/lib/system"
  for e in "$SDK"/*; do b="$(basename "$e")"; [ "$b" = "usr" ] || ln -s "$e" "$OV/$b"; done
  for e in "$SDK/usr"/*; do b="$(basename "$e")"; [ "$b" = "lib" ] || ln -s "$e" "$OV/usr/$b"; done
  for e in "$SDK/usr/lib"/*; do b="$(basename "$e")"
    if [ -d "$e" ] && [ "$b" != "system" ]; then ln -s "$e" "$OV/usr/lib/$b"
    elif [ -f "$e" ]; then cp "$e" "$OV/usr/lib/$b"; fi
  done
  cp "$SDK/usr/lib/system/"*.tbd "$OV/usr/lib/system/"
  perl -pi -e 's/\barm64e-macos\b/arm64-macos, arm64e-macos/ if /targets:/ && /arm64e-macos/ && !/\barm64-macos\b/;' \
    "$OV/usr/lib/"*.tbd "$OV/usr/lib/system/"*.tbd
  echo "sdk overlay: $OV"
fi
mkdir -p "$TOOLS/bin"
cat > "$TOOLS/bin/xcrun" <<'SHIM'
#!/bin/bash
for a in "$@"; do
  if [ "$a" = "--show-sdk-path" ]; then
    echo "${QUICKTERM_SDK:?QUICKTERM_SDK not set}"
    exit 0
  fi
done
exec /usr/bin/xcrun "$@"
SHIM
chmod +x "$TOOLS/bin/xcrun"
export QUICKTERM_SDK="$OV"
export PATH="$TOOLS/bin:$PATH"

cd "$GHOSTTY"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native

test -d "$OUT" || { echo "error: 未找到 $OUT"; exit 1; }

# --- 归档修复：Xcode 26.6 的 libtool 会因对齐问题丢弃 Zig 生成的归档成员
# --- （libghostty_zcu.o 等），导致 _ghostty_init/ImGui 符号缺失。
# --- 从全部组成档案重打完整 fat 归档，替换 xcframework 内的副本。
FAT="$OUT/macos-arm64/libghostty-fat.a"
if ! nm "$FAT" 2>/dev/null | grep -q "T _ghostty_init"; then
  echo "repacking fat archive (libtool dropped members)..."
  python3 - "$GHOSTTY" "$FAT" <<'PYEOF'
import os, subprocess, sys, tempfile
ghostty, fat = sys.argv[1], sys.argv[2]
cache = os.path.join(ghostty, ".zig-cache")
# 每个档案名只取最新一份（缓存可能残留多优化级别副本）
newest = {}
for root, _, files in os.walk(cache):
    for f in files:
        if f.endswith(".a") and "ghostty-fat" not in f:
            p = os.path.join(root, f)
            if f not in newest or os.path.getmtime(p) > os.path.getmtime(newest[f]):
                newest[f] = p
with tempfile.TemporaryDirectory() as tmp:
    objs = []
    for i, (name, path) in enumerate(sorted(newest.items())):
        d = os.path.join(tmp, f"d{i}")
        os.makedirs(d)
        subprocess.run(["ar", "x", path], cwd=d, check=True)
        for member in os.listdir(d):
            src = os.path.join(d, member)
            os.chmod(src, 0o644)
            if member.endswith(".o"):
                dst = os.path.join(tmp, f"{i}_{member}")
                os.rename(src, dst)
                objs.append(dst)
    out = os.path.join(tmp, "fat.a")
    subprocess.run(["ar", "qc", out] + objs, check=True)
    subprocess.run(["ranlib", out], check=True)
    syms = subprocess.run(["nm", out], capture_output=True, text=True).stdout
    assert " T _ghostty_init" in syms, "repack 后仍缺 _ghostty_init"
    subprocess.run(["cp", out, fat], check=True)
print("repacked:", fat)
PYEOF
fi

echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty （打包进 app bundle）"
