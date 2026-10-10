#!/bin/zsh
# Build the release installer: a clean Release build → signature checks → dist/Chilk-<version>.dmg + SHA256SUMS.txt.
#
# Needs Xcode 26, xcodegen (brew install xcodegen) and uv (for dmgbuild). The build must be signed with a stable
# identity from Config/Signing.local.xcconfig: an ad-hoc build is refused unless ALLOW_ADHOC=1, because macOS would ask
# users for every permission again after each update.
#
# usage: scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."

DERIVED=build/ReleaseDerivedData
APP="$DERIVED/Build/Products/Release/Chilk.app"
fail() { print -u2 "release: $*"; exit 1 }

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || print -u2 "release: warning — uncommitted changes are built in"

print "1/5 Release build (clean)…"
xcodegen generate --quiet
xcodebuild -project Chilk.xcodeproj -scheme Chilk -configuration Release -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' clean build > build/release-xcodebuild.log 2>&1 \
  || { grep -E "error:" build/release-xcodebuild.log | head -20; fail "xcodebuild failed (build/release-xcodebuild.log)"; }

print "2/5 Checking the app…"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
codesign --verify --strict "$APP" || fail "signature does not verify"
SIGN=$(codesign -dvv "$APP" 2>&1)
AUTHORITY=$(print -r -- "$SIGN" | sed -n 's/^Authority=//p' | head -1)
if [[ -z "$AUTHORITY" && "${ALLOW_ADHOC:-0}" != 1 ]]; then
  fail "ad-hoc signature: set CHILK_CODE_SIGN_IDENTITY in Config/Signing.local.xcconfig (or ALLOW_ADHOC=1)"
fi
print -r -- "$SIGN" | grep -q 'flags=0x10000(runtime)' || fail "hardened runtime is off"
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
[[ "$ENTITLEMENTS" != *get-task-allow* ]] || fail "get-task-allow in a release build"
for e in device.audio-input personal-information.calendars personal-information.reminders automation.apple-events; do
  [[ "$ENTITLEMENTS" == *"com.apple.security.$e"* ]] || fail "missing entitlement com.apple.security.$e"
done
for f in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do [[ -f "$APP/Contents/Resources/$f" ]] || fail "$f is not in the app"; done
print "   Chilk $VERSION ($BUILD), signed by ${AUTHORITY:-ad-hoc}, hardened runtime, $(du -sh "$APP" | cut -f1)"

print "3/5 DMG background…"
swift run --package-path ChilkKit -q chilk-render dmg build/dmg > /dev/null

print "4/5 DMG…"
mkdir -p dist
DMG="dist/Chilk-$VERSION.dmg"
rm -f "$DMG"
uvx --from 'dmgbuild==1.6.7' dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D background=build/dmg/dmg-background.png \
  "Чилк" "$DMG" > build/release-dmgbuild.log 2>&1 || { tail -20 build/release-dmgbuild.log; fail "dmgbuild failed"; }
hdiutil verify "$DMG" > /dev/null 2>&1 || fail "hdiutil verify failed"

print "5/5 Checksums…"
(cd dist && shasum -a 256 "Chilk-$VERSION.dmg" > SHA256SUMS.txt)
print "   $DMG — $(du -h "$DMG" | cut -f1)"
print "   $(cat dist/SHA256SUMS.txt)"
