#!/bin/bash
# Packages a built Deskset.app: ZIP plus a styled drag-to-Applications DMG.
# DMG tools are pinned in scripts/dmg/requirements.txt and isolated in build/dmg-tools.
#
#   scripts/package-app.sh build/arm64/Deskset.app 0.1.0 arm64
#
# Called by `build-app.sh --package`, and by the release workflow again after notarization has stapled the app.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 APP VERSION ARCH" >&2; exit 2; }
APP="$1"; VERSION="$2"; ARCH="$3"
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
cd "$(dirname "$0")/.."
NAME="$(basename "$APP" .app)"
[[ -d "$APP/Contents" ]] || { echo "Not an application bundle: $APP" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
case "$ARCH" in arm64|x86_64) ;; *) echo "ARCH must be arm64 or x86_64" >&2; exit 2 ;; esac

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "Packaging requires Python 3.10 or newer.")'
TOOLS="$PWD/build/dmg-tools"
REQUIREMENTS="$PWD/scripts/dmg/requirements.txt"
if [[ ! -x "$TOOLS/bin/python3" ]]; then
    python3 -m venv "$TOOLS"
    rm -f "$TOOLS/requirements.txt"
fi
if [[ ! -f "$TOOLS/requirements.txt" ]] || ! cmp -s "$REQUIREMENTS" "$TOOLS/requirements.txt"; then
    "$TOOLS/bin/python3" -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r "$REQUIREMENTS"
    cp "$REQUIREMENTS" "$TOOLS/requirements.txt"
fi

mkdir -p dist
BASE="dist/$NAME-$VERSION-$ARCH"
WORK="$(mktemp -d dist/.Deskset-package.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/app.zip"
cat > "$WORK/Install and Upgrade.txt" <<'GUIDE'
Install Deskset

Drag Deskset.app onto Applications, then open Deskset from Applications.
You can also open Deskset in this disk image and choose Install to Applications.
If no installation prompt appears, use the drag-and-drop steps above.

Upgrade an existing copy

1. Quit Deskset from its menu and save any edits.
2. Drag Deskset.app onto Applications and choose Replace, or open the app in
   this disk image and choose Replace and Open.
3. Open Deskset from Applications, then eject this disk image.

Your skins and settings are kept in ~/Library/Application Support/Deskset.
Replacing the application does not remove them. If macOS blocks the first
launch, allow Deskset in System Settings > Privacy & Security.

安装 Deskset

将 Deskset.app 拖到 Applications（应用程序），再从「应用程序」打开。
也可以打开磁盘映像中的 Deskset，点击「Install to Applications」。
如果没有出现安装提示，请按上述拖拽方式安装。

升级已有版本

1. 在 Deskset 菜单中选择 Quit Deskset，保存尚未保存的编辑。
2. 将 Deskset.app 拖到 Applications 并选择「替换」，或打开磁盘映像中的
   Deskset，点击「Replace and Open」。
3. 从「应用程序」打开 Deskset，再推出此磁盘映像。

皮肤与设置保存在 ~/Library/Application Support/Deskset，替换应用不会删除它们。
若首次打开被 macOS 阻止，请在「系统设置 > 隐私与安全性」中允许打开 Deskset。
GUIDE
swift scripts/dmg/render-background.swift "$WORK/background.tiff"
"$TOOLS/bin/python3" scripts/dmg/build-image.py \
    "$APP" "$PWD/$WORK/Install and Upgrade.txt" "$PWD/$WORK/background.tiff" \
    "$NAME $VERSION" "$WORK/app.dmg"
# Keep the previous downloads intact if copying or disk-image creation fails.
mv -f "$WORK/app.zip" "$BASE.zip"
mv -f "$WORK/app.dmg" "$BASE.dmg"
echo "Packaged $BASE.zip and $BASE.dmg"
