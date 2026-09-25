#!/usr/bin/env bash
# Release packaging: Release build → sign → (optional) notarize → DMG → appcast → (optional) upload
# to a GitHub Release. See docs/superpowers/specs/2026-09-25-auto-update-design.md §7.
#
# Usage: scripts/make-release.sh [--notarize] [--upload] [--first-release]
#   --notarize       Developer ID notarization: notarize and staple the .app itself first (so even
#                    an offline first launch clears Gatekeeper), then sign, notarize and staple the
#                    DMG (needs SIGN_IDENTITY + NOTARY_PROFILE)
#   --upload         Publish to the GitHub Release for tag v<version> (requires --notarize, a clean
#                    working tree, the tag pushed and pointing at HEAD so the published binary
#                    matches the tagged source one to one, both release-notes files committed in
#                    the tag, and `gh auth login`). The release is created as a draft with every
#                    asset and published in one step, so the update feed never points at a release
#                    without its appcast; a re-run finishes a draft an interrupted run left behind.
#   --first-release  Accept that no previous release carries an appcast.xml (the first updater
#                    release only)
# Environment variables:
#   SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"; unset = ad-hoc ("-"): no Sparkle
#                     signing and no appcast, downloaders clear Gatekeeper as the README says
#   NOTARY_PROFILE    The keychain profile saved by `xcrun notarytool store-credentials <name>`
#   E2E_BUNDLE_ID     Build under another bundle identifier (the end-to-end update test only)
#   E2E_BUILD_NUMBER  Build under another CFBundleVersion (the end-to-end update test only)
#                     Either one also compiles the app with UPDATE_E2E, so this Release build honours
#                     --update-feed-url (UpdateController.allowsFeedOverride); such builds are never
#                     uploaded.
#
# Single source of truth for the version: MARKETING_VERSION / CURRENT_PROJECT_VERSION in
# project.yml (read back from the built Info.plist). Output: build/QuickTerm-<version>.dmg,
# .dmg.sha256, build/appcast.xml, build/QuickTerm-<version>-notes(.zh-CN).md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
fail() { echo "error: $*" >&2; exit 1; }

REPO="dannyzhu/QuickTerm"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
# The Sparkle version pinned in project.yml, and the checksum of its SwiftPM zip (from Sparkle's
# Package.swift for that tag). The CLI tools (sign_update, generate_keys) come from the same zip.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"

NOTARIZE=0; UPLOAD=0; FIRST_RELEASE=""   # non-empty = --first-release
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --upload) UPLOAD=1 ;;
    --first-release) FIRST_RELEASE=1 ;;
    *) fail "unknown argument: ${arg} (available: --notarize --upload --first-release)" ;;
  esac
done
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$NOTARIZE" = 1 ] && { [ "$IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; }; then
  fail "--notarize requires SIGN_IDENTITY (Developer ID) and NOTARY_PROFILE"
fi
# Once an appcast is published every client is offered the DMG automatically, so an unnotarized
# upload is no longer a manual-download inconvenience but a Gatekeeper block for everyone.
[ "$UPLOAD" = 1 ] && [ "$NOTARIZE" = 0 ] && fail "--upload requires --notarize"
if [ -n "${E2E_BUNDLE_ID:-}${E2E_BUILD_NUMBER:-}" ] && [ "$UPLOAD" = 1 ]; then
  fail "E2E_BUNDLE_ID / E2E_BUILD_NUMBER builds are never uploaded"
fi
grep -q "exactVersion: $SPARKLE_VERSION" "$ROOT/project.yml" \
  || fail "project.yml pins a different Sparkle than SPARKLE_VERSION=$SPARKLE_VERSION in this script"

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

# Sparkle's CLI tools: the SwiftPM artifacts of a previous build, else a checksummed download.
SPARKLE_BIN=""
if [ "$IDENTITY" != "-" ]; then
  DERIVED="$ROOT/build/release"
  SPARKLE_BIN="$(find "$DERIVED/SourcePackages/artifacts" -type f -name sign_update -perm -u+x 2>/dev/null | head -1 || true)"
  SPARKLE_BIN="${SPARKLE_BIN:+$(dirname "$SPARKLE_BIN")}"
  if [ -z "$SPARKLE_BIN" ]; then
    TOOLS="$ROOT/.tools/sparkle-$SPARKLE_VERSION"
    if [ ! -x "$TOOLS/bin/sign_update" ]; then
      mkdir -p "$TOOLS"
      ZIPF="$TOOLS/Sparkle-for-Swift-Package-Manager.zip"
      curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" -o "$ZIPF"
      echo "$SPARKLE_SHA256  $ZIPF" | shasum -a 256 -c - >/dev/null || fail "Sparkle tools zip checksum mismatch"
      (cd "$TOOLS" && unzip -qo "$ZIPF" && rm -f "$ZIPF")
    fi
    SPARKLE_BIN="$TOOLS/bin"
  fi
  [ -x "$SPARKLE_BIN/sign_update" ] && [ -x "$SPARKLE_BIN/generate_keys" ] || fail "Sparkle tools not found under $SPARKLE_BIN"
  # The public key in project.yml must be the one whose private half sits in this Mac's Keychain,
  # or every client rejects the signature; and the Keychain must be reachable now, not after a
  # 10-minute build.
  PUBLIC_KEY="$(sed -n 's/^ *SUPublicEDKey: *"\{0,1\}\([A-Za-z0-9+/=]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
  [ -n "$PUBLIC_KEY" ] || fail "project.yml has no SUPublicEDKey: run generate_keys once and add the public key"
  KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]')" \
    || fail "generate_keys -p failed: the Sparkle EdDSA private key is not in this login Keychain (run $SPARKLE_BIN/generate_keys once for a new key, or import the backup with generate_keys -f <file>)"
  [ "$KEYCHAIN_KEY" = "$PUBLIC_KEY" ] || fail "SUPublicEDKey in project.yml does not match the key in the login Keychain (generate_keys -p)"
  SCRATCH="$(mktemp)"; echo probe > "$SCRATCH"
  "$SPARKLE_BIN/sign_update" "$SCRATCH" >/dev/null || fail "sign_update cannot sign (Keychain locked? run it once by hand and click Always Allow)"
  rm -f "$SCRATCH"
fi

# ── 1. Release build (wipe old products: a failed build must never pass off a stale .app as new)
DERIVED="$ROOT/build/release"
BUILD_LOG="$ROOT/build/release-build.log"
mkdir -p "$ROOT/build"
rm -rf "$DERIVED/Build/Products"
xcodegen generate >/dev/null
# The end-to-end test's apps are real Release builds (signing, appcast and all) that must still take
# a feed override: UPDATE_E2E is what UpdateController.allowsFeedOverride checks besides DEBUG. A
# shipped release never gets it, because the E2E variables refuse --upload above.
E2E_CONDITIONS=""
if [ -n "${E2E_BUNDLE_ID:-}${E2E_BUILD_NUMBER:-}" ]; then
  E2E_CONDITIONS='$(inherited) UPDATE_E2E'
  echo "▶ E2E build: bundle id ${E2E_BUNDLE_ID:-unchanged}, build ${E2E_BUILD_NUMBER:-unchanged}, compiled with UPDATE_E2E (honours --update-feed-url); never uploaded"
fi
echo "▶ Release build… (log: ${BUILD_LOG})"
# generic destination: builds for ARCHS_STANDARD (arm64 x86_64); without it Xcode falls back to
# "My Mac" and builds the native arch only. xcodebuild also fetches the Sparkle SwiftPM binary
# package (network; the same proxy note as for Zig applies).
if ! xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Release \
     -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
     ${E2E_BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$E2E_BUNDLE_ID"} \
     ${E2E_BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$E2E_BUILD_NUMBER"} \
     ${E2E_CONDITIONS:+SWIFT_ACTIVE_COMPILATION_CONDITIONS="$E2E_CONDITIONS"} \
     -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20 >&2
  fail "build failed (BUILD FAILED), see $BUILD_LOG"
fi
APP="$DERIVED/Build/Products/Release/QuickTerm.app"
[ -d "$APP" ] || fail "build did not produce $APP"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
# Sparkle offers an update only when this number is greater than the installed one's. 23 is the
# build 1.6.7 shipped as, the last release before the updater, so anything at or below it would
# never be offered to anyone.
case "$BUILD_NUMBER" in
  ''|*[!0-9]*) fail "CFBundleVersion '${BUILD_NUMBER}' is not an integer (Sparkle compares it as the build number)" ;;
esac
[ "$BUILD_NUMBER" -gt 23 ] || fail "build $BUILD_NUMBER is not greater than 23 (1.6.7's build): bump CURRENT_PROJECT_VERSION in project.yml"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
case "$MIN_SYSTEM" in *.*.*) ;; *) MIN_SYSTEM="$MIN_SYSTEM.0" ;; esac
TAG="v$VERSION"
# Arch check: a release build has to be a universal binary (GhosttyKit must be built with
# GHOSTTYKIT_TARGET=universal first)
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/QuickTerm")"
for want in ${RELEASE_ARCHS:-arm64 x86_64}; do
  case " $ARCHS_BUILT " in *" $want "*) ;; *) fail "build is missing arch ${want} (got: ${ARCHS_BUILT}). Run GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh first" ;; esac
done
echo "version ${VERSION} build ${BUILD_NUMBER} (archs: ${ARCHS_BUILT})"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[ "$(find "$APP/Contents/Frameworks" -maxdepth 1 -name 'Sparkle.framework' | wc -l | tr -d ' ')" = 1 ] \
  || fail "expected exactly one Contents/Frameworks/Sparkle.framework"
EMBEDDED_SPARKLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SPARKLE_FW/Resources/Info.plist")"
[ "$EMBEDDED_SPARKLE" = "$SPARKLE_VERSION" ] || fail "embedded Sparkle is $EMBEDDED_SPARKLE, expected $SPARKLE_VERSION"
# What the built app will ask for, not what project.yml says: a wrong feed URL shipped in a release
# strands every client of that release for good (the live-feed check below reads this script's
# FEED_URL, not the app's), and a key other than the Keychain's makes them reject every update.
BUILT_FEED="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST" 2>/dev/null || true)"
[ "$BUILT_FEED" = "$FEED_URL" ] || fail "built app's SUFeedURL is '${BUILT_FEED}', expected $FEED_URL"
if [ "$IDENTITY" != "-" ]; then
  BUILT_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
  [ "$BUILT_KEY" = "$PUBLIC_KEY" ] || fail "built app's SUPublicEDKey is '${BUILT_KEY}', expected project.yml's $PUBLIC_KEY"
fi

NOTES_EN="$ROOT/docs/releases/$TAG.md"
NOTES_ZH="$ROOT/docs/releases/$TAG.zh-CN.md"
if [ "$UPLOAD" = 1 ]; then
  git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null || fail "missing local tag ${TAG}: git tag $TAG"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] || fail "HEAD is not the commit that tag $TAG points at"
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "tag $TAG not pushed: git push origin $TAG"
  # Both notes files, in the tag: the app fetches them from the release assets by version.
  git cat-file -e "$TAG:docs/releases/$TAG.md" 2>/dev/null || fail "docs/releases/$TAG.md is not committed in $TAG"
  git cat-file -e "$TAG:docs/releases/$TAG.zh-CN.md" 2>/dev/null || fail "docs/releases/$TAG.zh-CN.md is not committed in $TAG"
fi

# ── 2. Sign: nested code first, then the app. The deprecated --deep would sign in the wrong order
#      and hand the app's entitlements to everything inside.
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
  # Nested code first, inside-out: the bundled CLI in SharedSupport is its own Mach-O, and the
  # notary service rejects the whole app if it is ad-hoc signed, lacks the hardened runtime or a
  # secure timestamp, or still carries the get-task-allow entitlement Xcode embeds at build time.
  # It needs no entitlements of its own, and re-signing without --entitlements drops Xcode's.
  while IFS= read -r -d '' nested; do
    file "$nested" | grep -q "Mach-O" || continue
    echo "  signing nested code: ${nested#"$APP"/}"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  done < <(find "$APP/Contents/SharedSupport" "$APP/Contents/Helpers" -type f -perm -u+x -print0 2>/dev/null)
  # Sparkle's nested code, by bundle path and inside-out (Sparkle's sandboxing guide): the XPC
  # services keep their entitlements. The unsandboxed app does not use them, but notarization
  # still wants them signed.
  for bundle in \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE_FW/Versions/B/Autoupdate" \
      "$SPARKLE_FW/Versions/B/Updater.app" \
      "$SPARKLE_FW"; do
    [ -e "$bundle" ] || fail "Sparkle layout changed, missing $bundle"
    echo "  signing Sparkle: ${bundle#"$APP"/}"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$bundle"
  done
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

# ── 3. Notarize and staple the .app itself (Apple's recommended order: app, then DMG)
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

# ── 6. Appcast: EdDSA-sign the final DMG and merge the item into the previous release's feed
APPCAST="$ROOT/build/appcast.xml"
NOTES_EN_ASSET="$ROOT/build/QuickTerm-$VERSION-notes.md"
NOTES_ZH_ASSET="$ROOT/build/QuickTerm-$VERSION-notes.zh-CN.md"
rm -f "$APPCAST" "$NOTES_EN_ASSET" "$NOTES_ZH_ASSET"
if [ "$IDENTITY" != "-" ]; then
  echo "▶ Appcast…"
  SIGNED="$("$SPARKLE_BIN/sign_update" "$DMG")"     # sparkle:edSignature="…" length="…"
  ED_SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  ED_LENGTH="$(printf '%s' "$SIGNED" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  [ -n "$ED_SIGNATURE" ] && [ -n "$ED_LENGTH" ] || fail "could not parse sign_update output: $SIGNED"
  [ "$ED_LENGTH" = "$(stat -f %z "$DMG")" ] || fail "sign_update length differs from the DMG size"
  PREVIOUS="$ROOT/build/appcast-previous.xml"; rm -f "$PREVIOUS"
  PREV_TAG=""
  if command -v gh >/dev/null; then
    PREV_TAG="$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 --json tagName -q '.[].tagName' 2>/dev/null | grep -Fvx "$TAG" | head -1 || true)"
  fi
  if [ -n "$PREV_TAG" ]; then
    curl -fsSL "https://github.com/$REPO/releases/download/$PREV_TAG/appcast.xml" -o "$PREVIOUS" || rm -f "$PREVIOUS"
  fi
  if [ ! -f "$PREVIOUS" ] && [ -z "$FIRST_RELEASE" ]; then
    if [ "$UPLOAD" = 1 ]; then
      fail "the previous release (${PREV_TAG:-none}) has no appcast.xml; pass --first-release only for the very first updater release"
    fi
    echo "warning: no previous appcast (${PREV_TAG:-none}); the dry run starts an empty feed"
    FIRST_RELEASE=1
  fi
  [ -f "$NOTES_EN" ] || fail "missing $NOTES_EN (the English notes are the appcast description)"
  python3 "$ROOT/scripts/update-appcast.py" --out "$APPCAST" --version "$VERSION" --build "$BUILD_NUMBER" \
    --min-system "$MIN_SYSTEM" --dmg-url "https://github.com/$REPO/releases/download/$TAG/QuickTerm-$VERSION.dmg" \
    --length "$ED_LENGTH" --signature "$ED_SIGNATURE" --notes "$NOTES_EN" \
    --notes-link "https://github.com/$REPO/releases/tag/$TAG" \
    ${FIRST_RELEASE:+--first-release} ${PREVIOUS:+--previous "$PREVIOUS"}
  grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST" || fail "appcast does not carry build $BUILD_NUMBER"
  grep -qF "sparkle:edSignature=\"$ED_SIGNATURE\"" "$APPCAST" || fail "appcast does not carry this DMG's EdDSA signature"
  grep -qF "length=\"$ED_LENGTH\"" "$APPCAST" || fail "appcast does not carry this DMG's length"
  [ -f "$NOTES_EN" ] && cp "$NOTES_EN" "$NOTES_EN_ASSET"
  [ -f "$NOTES_ZH" ] && cp "$NOTES_ZH" "$NOTES_ZH_ASSET"
  echo "OK: $APPCAST"
fi

# ── 7. GitHub Release (draft with every asset, then published in one step)
if [ "$UPLOAD" = 1 ]; then
  ASSETS=("$DMG" "$DMG.sha256" "$NOTES_EN_ASSET" "$NOTES_ZH_ASSET" "$APPCAST")
  for asset in "${ASSETS[@]}"; do [ -f "$asset" ] || fail "missing release asset $asset"; done
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    IS_DRAFT="$(gh release view "$TAG" -R "$REPO" --json isDraft -q .isDraft)"
    gh release upload "$TAG" "${ASSETS[@]}" -R "$REPO" --clobber
    # Still a draft: an earlier run stopped between creating the draft and publishing it. Its
    # assets are replaced above; publishing it is what that run did not get to.
    if [ "$IS_DRAFT" = "true" ]; then
      gh release edit "$TAG" -R "$REPO" --draft=false
    fi
  else
    gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --draft --verify-tag --title "QuickTerm $VERSION" --notes-file "$NOTES_EN"
    gh release edit "$TAG" -R "$REPO" --draft=false
  fi
  echo "published: $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
  # The live feed must advertise exactly this build, signature and size. GitHub's latest/download
  # redirect can lag the publish, so it gets six tries 10 s apart. Here-strings, not a pipe into
  # grep -q: with pipefail, grep leaving early on a feed larger than the pipe buffer would fail
  # the writer with SIGPIPE and turn a match into a miss.
  feed_lacks() {   # prints what the live feed is missing; nothing when it is right
    local live
    live="$(curl -fsSL "$FEED_URL" 2>/dev/null)" || { echo "the live feed at $FEED_URL is unreachable"; return 0; }
    grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" <<<"$live" || { echo "live feed lacks build $BUILD_NUMBER"; return 0; }
    grep -qF "sparkle:edSignature=\"$ED_SIGNATURE\"" <<<"$live" || { echo "live feed lacks this DMG's signature"; return 0; }
    grep -qF "length=\"$ED_LENGTH\"" <<<"$live" || { echo "live feed lacks this DMG's length"; return 0; }
  }
  LACKS=""
  for attempt in 1 2 3 4 5 6; do
    sleep 10
    LACKS="$(feed_lacks)"
    [ -z "$LACKS" ] && break
    echo "  ${LACKS} (try ${attempt}/6)"
  done
  [ -z "$LACKS" ] || fail "$LACKS"
  echo "feed OK: $FEED_URL"
fi
