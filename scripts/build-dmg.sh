#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Orbplay.xcodeproj"
SCHEME="Orbplay"
VERSION="1.2.0"
OUTPUT_DIR="$ROOT/dist"
OUTPUT="$OUTPUT_DIR/Orbplay-$VERSION-arm64.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/orbplay-dmg.XXXXXX")"
DERIVED="$STAGING/DerivedData"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$STAGING/image/Applications"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- \
  build

APP="$DERIVED/Build/Products/Release/Orbplay.app"
if [[ ! -d "$APP" ]]; then
  echo "Release app was not produced at $APP" >&2
  exit 1
fi

ditto "$APP" "$STAGING/image/Orbplay.app"
ln -s /Applications "$STAGING/image/Applications"
rm -f "$OUTPUT"
hdiutil create -volname "Orbplay $VERSION" -srcfolder "$STAGING/image" -ov -format UDZO "$OUTPUT"
echo "Created $OUTPUT"
