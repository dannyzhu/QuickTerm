#!/usr/bin/env bash
# 构建 GhosttyKit.xcframework。Zig 版本严格跟随 vendor/ghostty 的 pin。
#   GHOSTTYKIT_TARGET=native     本机架构（默认；开发迭代快）
#   GHOSTTYKIT_TARGET=universal  arm64 + x86_64 通用库（发布 DMG 用；Zig 交叉编译，无需 Rosetta）
set -euo pipefail
TARGET="${GHOSTTYKIT_TARGET:-native}"
case "$TARGET" in native|universal) ;; *) echo "error: GHOSTTYKIT_TARGET 须为 native|universal" >&2; exit 2 ;; esac

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
echo "building GhosttyKit ($TARGET)…"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target="$TARGET"

test -d "$OUT" || { echo "error: 未找到 $OUT"; exit 1; }

# --- 归档修复：Xcode 26.6 的 libtool 会因对齐问题丢弃 Zig 生成的归档成员
# --- （libghostty_zcu.o 等），导致 _ghostty_init/ImGui 符号缺失。
# --- 按架构分别检查；缺失的架构从缓存中该架构的全部组成档案重打，再 lipo 回通用归档。
# 切换 native/universal 后可能残留旧切片：只保留最新的一份
SLICE="$(ls -dt "$OUT"/macos-* | head -1)"
for d in "$OUT"/macos-*; do [ "$d" = "$SLICE" ] || { echo "removing stale slice $(basename "$d")"; rm -rf "$d"; }; done
FAT="$(ls "$SLICE"/*.a | head -1)"
python3 - "$GHOSTTY" "$FAT" <<'PYEOF'
import os, subprocess, sys, tempfile
ghostty, fat = sys.argv[1], sys.argv[2]
def archs(path):
    r = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else []
def has_init(path):
    return " T _ghostty_init" in subprocess.run(["nm", path], capture_output=True, text=True).stdout
def platform(path):
    # Mach-O LC_BUILD_VERSION 的 platform：1 = macOS，2 = iOS，7 = iOS 模拟器…；
    # universal 目标还会编 iOS 切片，其 arm64 归档与 macOS 同名，必须按平台过滤
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    i = out.find("LC_BUILD_VERSION")
    if i < 0:
        return 1 if "LC_VERSION_MIN_MACOSX" in out or "LC_VERSION_MIN" not in out else 0
    for line in out[i:i+400].splitlines():
        if line.strip().startswith("platform"):
            try: return int(line.split()[1])
            except ValueError: return 0
    return 0
fat_archs = archs(fat)
assert fat_archs, f"无法识别架构: {fat}"
with tempfile.TemporaryDirectory() as tmp:
    thins = {}
    for a in fat_archs:
        thin = os.path.join(tmp, f"thin-{a}.a")
        if len(fat_archs) > 1:
            subprocess.run(["lipo", fat, "-thin", a, "-output", thin], check=True)
        else:
            subprocess.run(["cp", fat, thin], check=True)
        thins[a] = thin
    need = [a for a, t in thins.items() if not has_init(t)]
    if not need:
        print("archive ok:", fat_archs); sys.exit(0)
    print("repacking archs (libtool dropped members):", need)
    cache = os.path.join(ghostty, ".zig-cache")
    newest = {}   # (档案名, 架构) → 最新一份（缓存可能残留多优化级别/多目标副本）
    for root, _, files in os.walk(cache):
        for f in files:
            if f.endswith(".a") and "ghostty-fat" not in f:
                p = os.path.join(root, f)
                pa = archs(p)
                if len(pa) != 1: continue   # 跳过通用（lipo 合成）归档，只取单架构组成档案
                if platform(p) != 1: continue   # 只取 macOS 平台（排除 iOS / 模拟器切片的同名归档）
                for a in pa:
                    k = (f, a)
                    if k not in newest or os.path.getmtime(p) > os.path.getmtime(newest[k]):
                        newest[k] = p
    for a in need:
        objs = []
        d0 = os.path.join(tmp, f"x-{a}"); os.makedirs(d0)
        for i, ((name, arch), path) in enumerate(sorted(newest.items())):
            if arch != a: continue
            d = os.path.join(d0, f"d{i}"); os.makedirs(d)
            subprocess.run(["ar", "x", path], cwd=d, check=True)
            for m in os.listdir(d):
                src = os.path.join(d, m); os.chmod(src, 0o644)
                if m.endswith(".o"):
                    dst = os.path.join(d0, f"{i}_{m}"); os.rename(src, dst); objs.append(dst)
        out = os.path.join(tmp, f"re-{a}.a")
        subprocess.run(["ar", "qc", out] + objs, check=True)
        subprocess.run(["ranlib", out], check=True)
        assert has_init(out), f"{a}: repack 后仍缺 _ghostty_init"
        thins[a] = out
    if len(thins) > 1:
        subprocess.run(["lipo", "-create"] + [thins[a] for a in fat_archs] + ["-output", fat], check=True)
    else:
        subprocess.run(["cp", next(iter(thins.values())), fat], check=True)
    print("repacked:", fat, archs(fat))
PYEOF
echo "archs: $(lipo -archs "$FAT")"

echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty （打包进 app bundle）"
