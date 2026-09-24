#!/usr/bin/env bash
# Release packaging: Release build → sign → (optional) notarize → DMG → (optional) upload to
# GitHub Release
#
# Usage: scripts/make-release.sh [--notarize] [--upload]
#   --notarize  Developer ID notarization: notarize and staple the .app itself first (so even an
#               offline first launch clears Gatekeeper), then sign, notarize and staple the DMG
#               (needs SIGN_IDENTITY + NOTARY_PROFILE)
#   --upload    Upload to a GitHub Release: requires a clean working tree and tag v<version>
#               already pushed to origin and pointing at HEAD (so the published binary matches
#               the tagged source one to one; needs `gh auth login`)
# Environment variables:
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"; unset = ad-hoc signing ("-"), and
#                   downloaders clear Gatekeeper as described in the README's "Install" section
#   NOTARY_PROFILE  The keychain profile name saved by `xcrun notarytool store-credentials <name>`
#
# Single source of truth for the version: MARKETING_VERSION in project.yml (read back from the
# built Info.plist).
# Output: build/QuickTerm-<version>.dmg and .dmg.sha256 (the checksum file holds only the file
# name, so downloaders can run shasum -c directly)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
fail() { echo "error: $*" >&2; exit 1; }

NOTARIZE=0; UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --upload) UPLOAD=1 ;;
    *) fail "unknown argument: ${arg} (available: --notarize --upload)" ;;
  esac
done
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$NOTARIZE" = 1 ] && { [ "$IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; }; then
  fail "--notarize requires SIGN_IDENTITY (Developer ID) and NOTARY_PROFILE"
fi

# ── 0. Preflight checks
cd "$ROOT"
[ -d vendor/ghostty/macos/GhosttyKit.xcframework ] || fail "missing GhosttyKit.xcframework, run scripts/build-ghosttykit.sh first"
find Themes -path '*/backgrounds/*' -type f | grep -q . || fail "missing theme wallpapers, run scripts/fetch-themes.sh first"
if [ "$UPLOAD" = 1 ]; then
  # --ignore-submodules=dirty: vendor/ghostty is a submodule that build-ghosttykit.sh deliberately
  # dirties by applying patches/ghostty/, so dirty content there is expected; a changed submodule
  # *pointer* is still uncommitted work and still fails the check.
  git diff --quiet --ignore-submodules=dirty && git diff --cached --quiet --ignore-submodules=dirty \
    || fail "uncommitted changes in the working tree, --upload requires a clean HEAD"
  command -v gh >/dev/null || fail "missing gh CLI (brew install gh && gh auth login)"
fi

# ── 1. Release build (wipe old products: a failed build must never pass off a stale .app as new)
DERIVED="$ROOT/build/release"
BUILD_LOG="$ROOT/build/release-build.log"
mkdir -p "$ROOT/build"
rm -rf "$DERIVED/Build/Products"
xcodegen generate >/dev/null
echo "▶ Release build… (log: ${BUILD_LOG})"
# generic destination: builds for ARCHS_STANDARD (arm64 x86_64); without it Xcode falls back to
# "My Mac" and builds the native arch only
if ! xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Release \
     -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
     -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20 >&2
  fail "build failed (BUILD FAILED), see $BUILD_LOG"
fi
APP="$DERIVED/Build/Products/Release/QuickTerm.app"
[ -d "$APP" ] || fail "build did not produce $APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
# Arch check: a release build has to be a universal binary (GhosttyKit must be built with
# GHOSTTYKIT_TARGET=universal first)
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/QuickTerm")"
for want in ${RELEASE_ARCHS:-arm64 x86_64}; do
  case " $ARCHS_BUILT " in *" $want "*) ;; *) fail "build is missing arch ${want} (got: ${ARCHS_BUILT}). Run GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh first" ;; esac
done
echo "version ${VERSION} (archs: ${ARCHS_BUILT})"

if [ "$UPLOAD" = 1 ]; then
  git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null || fail "missing local tag ${TAG}: git tag $TAG"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] || fail "HEAD is not the commit that tag $TAG points at"
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "tag $TAG not pushed: git push origin $TAG"
fi

# ── 2. Sign (the app is statically linked with no nested code, so no need for deprecated --deep)
echo "▶ Signing (${IDENTITY})…"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  # A real identity gets the hardened runtime (required for notarization) and the entitlements a
  # terminal needs so the programs it runs can still reach the camera/mic/contacts/etc. The stable
  # Developer ID identity is also what makes macOS notification and TCC grants survive a rebuild —
  # an ad-hoc signature binds them to the cdhash, which changes every build.
  ENTITLEMENTS="$ROOT/QuickTerm.entitlements"
  [ -f "$ENTITLEMENTS" ] || fail "missing $ENTITLEMENTS (needed for a hardened-runtime signature)"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

# ── 3. Notarize and staple the .app itself (optional; Apple's recommended order: app, then DMG)
if [ "$NOTARIZE" = 1 ]; then
  ZIP="$ROOT/build/QuickTerm-$VERSION-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▶ Notarizing .app…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# ── 4. DMG (drag-to-Applications layout)
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/QuickTerm-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
echo "▶ Packaging DMG…"
hdiutil create -volname "QuickTerm $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
if [ "$IDENTITY" != "-" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ── 5. Checksum (file name only, so downloaders can just run
#      `shasum -a 256 -c QuickTerm-<version>.dmg.sha256` in the same directory)
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. GitHub Release (optional; if it already exists, only the assets are updated)
if [ "$UPLOAD" = 1 ]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  else
    NOTES="$ROOT/docs/releases/$TAG.md"   # hand-written notes if present, else gh generates them
    if [ -f "$NOTES" ]; then
      gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "QuickTerm $VERSION" --notes-file "$NOTES"
    else
      gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "QuickTerm $VERSION" --generate-notes
    fi
  fi
  echo "published: $(gh release view "$TAG" --json url -q .url)"
fi
