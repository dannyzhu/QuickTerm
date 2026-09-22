#!/usr/bin/env bash
# Build GhosttyKit.xcframework. The Zig version strictly follows the pin in vendor/ghostty.
#   GHOSTTYKIT_TARGET=native     Native arch (default; fast for development)
#   GHOSTTYKIT_TARGET=universal  arm64 + x86_64 universal library (for the release DMG; Zig
#                                cross-compiles, no Rosetta needed)
#   GHOSTTYKIT_SDK=<path>        Build against this macOS SDK instead of the active one (see the
#                                SDK section below for why you would)
set -euo pipefail
TARGET="${GHOSTTYKIT_TARGET:-native}"
case "$TARGET" in native|universal) ;; *) echo "error: GHOSTTYKIT_TARGET must be native|universal" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
OUT="$GHOSTTY/macos/GhosttyKit.xcframework"

ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
[ -n "$ZIG_VERSION" ] || { echo "error: cannot parse the Zig version from build.zig.zon"; exit 1; }

case "$(uname -m)" in
  arm64) ZARCH=aarch64 ;;
  *)     ZARCH=x86_64  ;;
esac

ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG" ]; then
  mkdir -p "$TOOLS"
  # Since 0.14.1 the name is zig-<arch>-macos-<ver>, earlier it was zig-macos-<arch>-<ver>; try both
  for NAME in "zig-$ZARCH-macos-$ZIG_VERSION" "zig-macos-$ZARCH-$ZIG_VERSION"; do
    URL="https://ziglang.org/download/$ZIG_VERSION/$NAME.tar.xz"
    echo "trying to download $URL"
    if curl -fL "$URL" -o "$TOOLS/zig.tar.xz"; then
      tar -xJf "$TOOLS/zig.tar.xz" -C "$TOOLS"
      mv "$TOOLS/$NAME" "$TOOLS/zig-$ZIG_VERSION"
      rm "$TOOLS/zig.tar.xz"
      break
    fi
  done
  [ -x "$ZIG" ] || { echo "error: failed to download Zig $ZIG_VERSION"; exit 1; }
fi
echo "using zig: $("$ZIG" version)"

# --- SDK overlay: the main tbd documents of the Xcode 26.x SDK lack an arm64-macos target, and
# --- the Zig 0.15 linker does not fall back from arm64 to arm64e, so every symbol ends up
# --- undefined. Build a symlink overlay that copies and patches only the tbd files under
# --- usr/lib, and point an xcrun shim at it.
# The SDK to build against. GHOSTTYKIT_SDK overrides the active one: the macOS 27 SDK guards
# INFINITY in math.h behind __has_include(<float.h>), which Zig 0.15.2's bundled libcxx does not
# satisfy (random.cpp: "use of undeclared identifier 'INFINITY'"), so on macOS 27 point this at
# the Command Line Tools' MacOSX26.5.sdk until Ghostty moves to a Zig whose libcxx copes. The
# result is a static library, so the app itself still builds against the active SDK as usual.
SDK="${GHOSTTYKIT_SDK:-$(/usr/bin/xcrun --show-sdk-path)}"
[ -d "$SDK/usr/include" ] || { echo "error: SDK not found: $SDK" >&2; exit 1; }
echo "using sdk: $SDK"
# One overlay per SDK, or switching SDKs would leave the symlinks pointing at the previous one
OV="$TOOLS/sdk-arm64fix-$(basename "$(readlink -f "$SDK")")"
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

# --- Engine patches: QuickTerm's own changes to the vendored engine source, kept as diffs under
# --- patches/ghostty/ (generated with `git -C vendor/ghostty diff`). Applied idempotently: a
# --- patch already in place is skipped; one that no longer applies aborts the build rather than
# --- silently producing an unpatched engine.
PATCHES="$ROOT/patches/ghostty"
if [ -d "$PATCHES" ]; then
  for p in "$PATCHES"/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$GHOSTTY" apply --check "$p" 2>/dev/null; then
      git -C "$GHOSTTY" apply "$p"
      echo "engine patch applied: $(basename "$p")"
    elif git -C "$GHOSTTY" apply --reverse --check "$p" 2>/dev/null; then
      echo "engine patch already applied: $(basename "$p")"
    else
      echo "error: engine patch does not apply cleanly: $p" >&2
      exit 1
    fi
  done
fi

cd "$GHOSTTY"
echo "building GhosttyKit ($TARGET)…"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target="$TARGET"

test -d "$OUT" || { echo "error: $OUT not found"; exit 1; }

# --- Archive fix: libtool in Xcode 26.6 drops archive members produced by Zig
# --- (libghostty_zcu.o and friends) over alignment issues, which loses the _ghostty_init/ImGui
# --- symbols. Check each arch separately; a missing arch is repacked from every component
# --- archive of that arch in the cache, then lipo'd back into the universal archive.
# Switching between native/universal can leave a stale slice behind: keep only the newest one
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
    # Mach-O LC_BUILD_VERSION platform: 1 = macOS, 2 = iOS, 7 = iOS simulator, ...; the universal
    # target also builds iOS slices whose arm64 archives share macOS names, so filter by platform
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
assert fat_archs, f"cannot determine archs: {fat}"
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
    newest = {}   # (archive name, arch) → newest (cache may keep several opt-level/target copies)
    for root, _, files in os.walk(cache):
        for f in files:
            if f.endswith(".a") and "ghostty-fat" not in f:
                p = os.path.join(root, f)
                pa = archs(p)
                if len(pa) != 1: continue   # skip universal (lipo) archives, take single-arch ones
                if platform(p) != 1: continue   # macOS only (iOS/simulator slices share names)
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
        assert has_init(out), f"{a}: _ghostty_init still missing after repack"
        thins[a] = out
    if len(thins) > 1:
        subprocess.run(["lipo", "-create"] + [thins[a] for a in fat_archs] + ["-output", fat], check=True)
    else:
        subprocess.run(["cp", next(iter(thins.values())), fat], check=True)
    print("repacked:", fat, archs(fat))
PYEOF
echo "archs: $(lipo -archs "$FAT")"

echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty (bundled into the app)"
