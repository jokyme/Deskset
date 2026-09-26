#!/bin/bash
# Builds Deskset.app: release build, bundle layout, Info.plist, example skins, license files, signature.
#
#   scripts/build-app.sh                       build/Deskset.app for this Mac's architecture
#   scripts/build-app.sh --arch x86_64         build/x86_64/Deskset.app (arm64 or x86_64)
#   scripts/build-app.sh --arch arm64 --package
#                                              also writes dist/Deskset-<version>-<arch>.zip and .dmg
#   scripts/build-app.sh --plist OUT.plist     only writes the Info.plist (checked by `Deskset --self-test plist`)
#
# Options: --version X.Y.Z (default: DesksetCore's version), --build-number N (default: the commit count).
# Signing: ad-hoc by default. With DESKSET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" the app is signed
# for distribution (hardened runtime, scripts/Deskset.entitlements, secure timestamp); notarize the zip or dmg after
# that (see .github/workflows/release.yml).
set -euo pipefail
# A relative OUT.plist is relative to where the script was started, not to the repository.
CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."

APP_NAME="Deskset"
BUNDLE_ID="app.deskset.Deskset"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/DesksetCore/DesksetCore.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCH=""
PACKAGE=0
PLIST_OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plist) PLIST_OUT="${2:-}"; [[ -n "$PLIST_OUT" ]] || { echo "usage: $0 --plist OUT.plist" >&2; exit 2; }; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
        --package) PACKAGE=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see $0 --help)" >&2; exit 2 ;;
    esac
done

# The app's Info.plist. Usage descriptions are the texts macOS shows in its permission prompts; a bundled app that
# touches a protected resource without the matching key is killed by the system, so every permission a skin can
# trigger has one (see docs/compat/app.md, "Permissions").
write_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- WebParser skins fetch plain http:// feeds (weather, RSS…): App Transport Security would block them. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSHumanReadableCopyright</key><string>Free software under the GNU GPL v3. Runs skins made for Rainmeter; not affiliated with Rainmeter. Rainmeter is a trademark of its respective owners.</string>

    <!-- Permission prompts (asked only when a loaded skin needs the feature). -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audio visualizer skins show the level and spectrum of the sound your Mac is playing. The audio is analysed on your Mac while such a skin is loaded; it is never recorded, saved or sent anywhere.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>A skin wants to show the level of an audio input (a microphone or an audio interface). The audio is analysed on your Mac while the skin is loaded; it is never recorded, saved or sent anywhere.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Skins ask Music or Spotify what is playing to show the current track and control playback, and ask Finder to empty the Trash or open a Get Info window when you use such a skin.</string>
    <key>NSLocationUsageDescription</key>
    <string>macOS shares Wi-Fi network names only with apps allowed to use Location Services. ${APP_NAME} uses this only to show network names in Wi-Fi skins; your location is never read or stored.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS shares Wi-Fi network names only with apps allowed to use Location Services. ${APP_NAME} uses this only to show network names in Wi-Fi skins; your location is never read or stored.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>A skin or its script reads or writes files in your Desktop folder (for example a file list, notes or launcher skin).</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>A skin or its script reads or writes files in your Documents folder (for example a file list, notes or launcher skin).</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>A skin or its script reads or writes files in your Downloads folder (for example a file list or launcher skin).</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>A skin or its script reads files on a removable drive (for example a disk or file list skin).</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>A skin or its script reads files on a network volume (for example a disk or file list skin).</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>A skin reads information from a device on your local network, such as a router status page or a home server.</string>

    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Skin Package</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>app.deskset.rmskin</string></array>
        </dict>
        <!-- Skins downloaded as plain ZIP archives or already extracted folders can be opened with Deskset
             (Open With, dropping on the app icon). Alternate: Deskset never becomes the default app for them. -->
        <dict>
            <key>CFBundleTypeName</key><string>ZIP Archive</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.pkware.zip-archive</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.deskset.rmskin</string>
            <key>UTTypeDescription</key><string>Skin Package</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>rmskin</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
    plutil -lint -s "$1"
}

if [[ -n "$PLIST_OUT" ]]; then
    case "$PLIST_OUT" in
        /*) write_plist "$PLIST_OUT" ;;
        *) write_plist "$CALLER_DIR/$PLIST_OUT" ;;
    esac
    exit 0
fi

HOST_ARCH="$(uname -m)"
if [[ -z "$ARCH" ]]; then
    ARCH="$HOST_ARCH"
    APP="build/$APP_NAME.app"
else
    APP="build/$ARCH/$APP_NAME.app"
fi
case "$ARCH" in arm64|x86_64) ;; *) echo "--arch must be arm64 or x86_64" >&2; exit 2 ;; esac

swift build -c release --arch "$ARCH" --product "$APP_NAME"
BIN="$(swift build -c release --arch "$ARCH" --product "$APP_NAME" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# Example skins are plain files, located at runtime via Bundle.main.resourceURL (no SPM resources).
ditto DefaultSkins "$APP/Contents/Resources/DefaultSkins"

# License texts travel with the app; the About panel shows Credits.html.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cat > "$APP/Contents/Resources/Credits.html" <<'CREDITS'
<div style="font: 11px -apple-system; text-align: center">
<p>Free software under the GNU General Public License v3.</p>
<p>Includes Lua 5.1.5 &copy; 1994–2012 Lua.org, PUC-Rio (MIT license).</p>
<p>Runs skins made for Rainmeter. Not affiliated with or endorsed by Rainmeter;<br>
Rainmeter is a trademark of its respective owners.</p>
</div>
CREDITS

# App icon: drawn in code by the app itself (AppIcon.swift), turned into an .icns by iconutil. A binary built for
# the other architecture may not run on this Mac (no Rosetta), so the icon then comes from a build for this Mac.
ICON_BIN="$BIN"
if ! "$ICON_BIN" --help > /dev/null 2>&1; then
    swift build -c release --product "$APP_NAME"
    ICON_BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
fi
ICONSET="build/$APP_NAME-$ARCH.iconset"
rm -rf "$ICONSET"
"$ICON_BIN" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICONSET"

write_plist "$APP/Contents/Info.plist"

if [[ -n "${DESKSET_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements scripts/Deskset.entitlements \
        -s "$DESKSET_SIGN_IDENTITY" "$APP"
    SIGNED="Developer ID"
else
    codesign --force -s - "$APP"
    SIGNED="ad-hoc"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER, $ARCH, $SIGNED signature)"

# The local build (no --arch) is the one double-clicked .rmskin files should open: register it with Launch Services,
# as Xcode does for the apps it builds. Architecture builds are only packaged.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "$APP" == "build/$APP_NAME.app" && -x "$LSREGISTER" && -z "${CI:-}" ]]; then
    "$LSREGISTER" -f "$APP" || true
fi

if [[ "$PACKAGE" == 1 ]]; then
    bash scripts/package-app.sh "$APP" "$VERSION" "$ARCH"
fi
