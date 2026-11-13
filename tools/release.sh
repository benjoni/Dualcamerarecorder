#!/bin/bash
# Builds a universal Release, signs it with Developer ID (Hardened Runtime), notarizes it, staples the
# ticket and zips it into dist/.  For distribution outside the Mac App Store.
#
# Usage (from the repository root):
#   tools/release.sh                 build + sign + notarize + staple + zip
#   tools/release.sh --no-notarize   build + sign + zip only (local testing)
#
# One-time setup for notarization (stores the app-specific password in the keychain):
#   xcrun notarytool store-credentials DualCamNotary --apple-id <apple-id> --team-id T8QNB934G2
set -euo pipefail

IDENTITY="Developer ID Application: Benjoni s.r.o. (T8QNB934G2)"
PROFILE="DualCamNotary"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/tools/DualCamRecorder-direct.entitlements"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

cd "$ROOT"
PBX=DualCamRecorder.xcodeproj/project.pbxproj
VERSION=$(grep -m1 'MARKETING_VERSION' "$PBX" | sed 's/.*= *\(.*\);/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBX" | sed 's/.*= *\(.*\);/\1/')
NAME="DualCamRecorder-$VERSION-$BUILD"
echo "==> $NAME"

echo "==> Building universal Release"
xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder -configuration Release \
  -derivedDataPath build-release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  build -quiet

# Sign in a temporary folder: the project lives in an iCloud-synced folder, which keeps adding
# Finder metadata (com.apple.FinderInfo) that codesign refuses.
mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/DualCamRecorder.app"
ditto build-release/Build/Products/Release/DualCamRecorder.app "$APP"
xattr -cr "$APP"

echo "==> Signing"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

ZIP="$STAGE/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if (( NOTARIZE )); then
  echo "==> Notarizing (a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  # Stapling downloads the ticket from Apple – retry when the connection drops.
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$APP"; then break; fi
    if [ "$attempt" = 5 ]; then echo "Stapling failed – notarized, but run: xcrun stapler staple <app>" >&2; exit 1; fi
    sleep 15
  done
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"          # zip again so it contains the stapled ticket
  spctl --assess --type execute --verbose "$APP"
fi

mv -f "$ZIP" "dist/$NAME.zip"
echo "==> Done: dist/$NAME.zip"
