#!/usr/bin/env bash
# 打 Release 包：Release 构建 → 签名 →（可选）公证 → DMG →（可选）上传 GitHub Release
#
# 用法：scripts/make-release.sh [--notarize] [--upload]
#   --notarize  Developer ID 公证：先公证并装订 .app 本体（离线首启也能过 Gatekeeper），
#               再签名、公证并装订 DMG（需 SIGN_IDENTITY + NOTARY_PROFILE）
#   --upload    上传到 GitHub Release：要求工作区干净、tag v<版本> 已推送到 origin 且指向 HEAD
#               （保证发布的二进制与 tag 源码一一对应；需已 `gh auth login`）
# 环境变量：
#   SIGN_IDENTITY   "Developer ID Application: 名字 (TEAMID)"；未设置 = ad-hoc 签名（"-"），
#                   下载者需按 README「Install」一节处理 Gatekeeper
#   NOTARY_PROFILE  `xcrun notarytool store-credentials <名>` 保存的 keychain profile 名
#
# 版本号唯一来源：project.yml 的 MARKETING_VERSION（经构建产物 Info.plist 读取）。
# 产物：build/QuickTerm-<版本>.dmg 与 .dmg.sha256（校验文件只含文件名，下载者可直接 shasum -c）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
fail() { echo "错误：$*" >&2; exit 1; }

NOTARIZE=0; UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --upload) UPLOAD=1 ;;
    *) fail "未知参数: $arg（可用：--notarize --upload）" ;;
  esac
done
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$NOTARIZE" = 1 ] && { [ "$IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; }; then
  fail "--notarize 需要 SIGN_IDENTITY（Developer ID）与 NOTARY_PROFILE"
fi

# ── 0. 前置检查
cd "$ROOT"
[ -d vendor/ghostty/macos/GhosttyKit.xcframework ] || fail "缺 GhosttyKit.xcframework，先跑 scripts/build-ghosttykit.sh"
find Themes -path '*/backgrounds/*' -type f | grep -q . || fail "缺主题壁纸，先跑 scripts/fetch-themes.sh"
if [ "$UPLOAD" = 1 ]; then
  git diff --quiet && git diff --cached --quiet || fail "工作区有未提交改动，--upload 要求干净的 HEAD"
  command -v gh >/dev/null || fail "缺 gh CLI（brew install gh && gh auth login）"
fi

# ── 1. Release 构建（清掉旧产物：构建失败绝不拿残留 .app 冒充新产物）
DERIVED="$ROOT/build/release"
BUILD_LOG="$ROOT/build/release-build.log"
mkdir -p "$ROOT/build"
rm -rf "$DERIVED/Build/Products"
xcodegen generate >/dev/null
echo "▶ Release 构建…（日志 $BUILD_LOG）"
if ! xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Release \
     -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20 >&2
  fail "构建失败（BUILD FAILED），见 $BUILD_LOG"
fi
APP="$DERIVED/Build/Products/Release/QuickTerm.app"
[ -d "$APP" ] || fail "构建未产出 $APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
echo "版本 $VERSION"

if [ "$UPLOAD" = 1 ]; then
  git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null || fail "缺本地 tag $TAG：git tag $TAG"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] || fail "HEAD 不是 tag $TAG 指向的提交"
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "tag $TAG 未推送：git push origin $TAG"
fi

# ── 2. 签名（app 为静态链接、无嵌套代码；不用已弃用的 --deep）
echo "▶ 签名（$IDENTITY）…"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

# ── 3. 公证并装订 .app 本体（可选；Apple 推荐顺序：先 app 后 DMG）
if [ "$NOTARIZE" = 1 ]; then
  ZIP="$ROOT/build/QuickTerm-$VERSION-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▶ 公证 .app…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# ── 4. DMG（拖入 Applications 布局）
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/QuickTerm-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
echo "▶ 打包 DMG…"
hdiutil create -volname "QuickTerm $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
if [ "$IDENTITY" != "-" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  echo "▶ 公证 DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ── 5. 校验和（只含文件名：下载者在同目录 `shasum -a 256 -c QuickTerm-<版本>.dmg.sha256` 即可）
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. GitHub Release（可选；已存在则只更新附件）
if [ "$UPLOAD" = 1 ]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  else
    gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag \
      --title "QuickTerm $VERSION" --generate-notes
  fi
  echo "已发布：$(gh release view "$TAG" --json url -q .url)"
fi
