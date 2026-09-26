#!/bin/bash
# Packages a built Deskset.app for download: dist/Deskset-<version>-<arch>.zip and .dmg (with an Applications link).
#
#   scripts/package-app.sh build/arm64/Deskset.app 0.1.0 arm64
#
# Called by `build-app.sh --package`, and by the release workflow again after notarization has stapled the app.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 APP VERSION ARCH" >&2; exit 2; }
APP="$1"; VERSION="$2"; ARCH="$3"
cd "$(dirname "$0")/.."
NAME="$(basename "$APP" .app)"

mkdir -p dist
BASE="dist/$NAME-$VERSION-$ARCH"
rm -f "$BASE.zip" "$BASE.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BASE.zip"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$BASE.dmg"
rm -rf "$STAGE"
echo "Packaged $BASE.zip and $BASE.dmg"
