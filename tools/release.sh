#!/bin/bash
# Builds a universal Release, signs it with Developer ID (Hardened Runtime), notarizes it, staples the
# ticket and zips it into dist/.  For distribution outside the Mac App Store.
#
# Usage (from the repository root):
#   tools/release.sh                 build + sign + notarize + staple + zip
#   tools/release.sh --no-notarize   build + sign + zip only (local testing)
#
# Before a release: write what is new into tools/release-notes.txt (one line each) – it goes into
# website/version.json, which the app's update check reads.
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

# Website: the zip in website/download/ and version.json (what the app's update check reads), with the lines of
# tools/release-notes.txt as "What's new". Only for a notarized build. Upload both, then the app offers it.
if (( NOTARIZE )); then
  mkdir -p website/download
  cp -f "dist/$NAME.zip" "website/download/$NAME.zip"
  python3 - "$VERSION" "$BUILD" "$NAME.zip" tools/release-notes.txt > website/version.json <<'PY'
import json, sys, datetime, os
version, build, zip_name, notes_file = sys.argv[1:5]
notes = []
if os.path.exists(notes_file):
    notes = [l.strip().lstrip("-•").strip() for l in open(notes_file, encoding="utf-8") if l.strip() and not l.startswith("#")]
print(json.dumps({"version": version, "build": int(build),
                  "url": f"https://dualrecorder.benjoni.com/download/{zip_name}",
                  "notes": notes, "date": datetime.date.today().isoformat()}, ensure_ascii=False, indent=2))
PY
  echo "==> Website: website/download/$NAME.zip and website/version.json – upload them:"
  echo "    cd website && printf 'cd benjoni.com/sub/dualrecorder\nmkdir download\nput download/$NAME.zip download/\nput version.json\nbye\n' | sftp dualrecorder.benjoni.com@benjoni.com"
fi
