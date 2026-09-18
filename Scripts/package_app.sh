#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Markdown2"     # SPM product / executable name inside the bundle
DISPLAY_NAME="Markdown2" # CFBundleName and the distributed .app/.dmg file name
APP_DIR="$ROOT_DIR/dist/$DISPLAY_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Derive the marketing version from the build tag so the About panel matches
# the GitHub release. Priority: explicit MARKDOWN2_VERSION, then the CI ref name
# (e.g. "v0.2.0"), then `git describe`. The leading "v" is stripped.
VERSION_RAW="${MARKDOWN2_VERSION:-${GITHUB_REF_NAME:-}}"
if [ -z "$VERSION_RAW" ]; then
    VERSION_RAW="$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || true)"
fi
VERSION="${VERSION_RAW#v}"
if [ -z "$VERSION" ]; then
    VERSION="0.0.0-dev"
fi

COPYRIGHT="Copyright © 2026 stutiredboy"

cd "$ROOT_DIR"
swift build -c release --product "$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Copy SwiftPM resource bundles (e.g. MD2_MD2Core.bundle, which carries the
# bundled KaTeX and diagram assets) into Contents/Resources. This is the only
# location a `.app` can hold extra content and still be code-signed: anything
# placed beside Contents/ at the bundle root is rejected by codesign as
# "unsealed contents present in the bundle root", which invalidates the
# signature and makes the app get killed by AMFI on launch. MD2Core resolves the
# bundle from Contents/Resources at runtime (see MD2CoreResources), so it no
# longer depends on the build-machine-only .build fallback path.
RELEASE_BIN_DIR="$(cd "$ROOT_DIR/.build/release" && pwd)"
shopt -s nullglob
for bundle in "$RELEASE_BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$RESOURCES_DIR/$(basename "$bundle")"
done
shopt -u nullglob

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeIconFile</key>
            <string>AppIcon.icns</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string>
                <string>markdown</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.markdown</string>
                <string>public.plain-text</string>
            </array>
            <key>LSHandlerRank</key>
            <string>Owner</string>
        </dict>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>dev.codex.md2</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>$COPYRIGHT</string>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.text</string>
            </array>
            <key>UTTypeDescription</key>
            <string>Markdown Document</string>
            <key>UTTypeIdentifier</key>
            <string>net.daringfireball.markdown</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string>
                    <string>markdown</string>
                </array>
                <key>public.mime-type</key>
                <string>text/markdown</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Code-sign the fully assembled bundle. An ad-hoc signature (-) is enough to
# satisfy AMFI on the local machine and seals Contents/ so the app is not killed
# on launch. Override MARKDOWN2_CODESIGN_IDENTITY to sign with a Developer ID for
# distribution. --force replaces the linker's ad-hoc signature on the binary.
CODESIGN_IDENTITY="${MARKDOWN2_CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# Launch Services bookkeeping.
#
# dist/ is a build artifact, not an install. Finder's "Open With" menu lists
# every registered copy of the app, so registering dist/ adds one more menu entry
# per build. Register only the installed copy instead, and drop whatever
# registration the dist bundle picked up previously.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
INSTALL_APP="${MARKDOWN2_INSTALL_APP:-/Applications/$DISPLAY_NAME.app}"

# CI only needs the dist/ artifact; installing into /Applications is local-only.
if [ -z "${CI:-}" ]; then
    case "$INSTALL_APP" in
        *.app) ;;
        *) echo "MARKDOWN2_INSTALL_APP must end in .app (got: $INSTALL_APP)" >&2; exit 1 ;;
    esac
    rm -rf "$INSTALL_APP"
    # ditto, not cp: it carries the bundle's code signature and extended
    # attributes over intact, which a fresh ad-hoc-signed build depends on.
    ditto "$APP_DIR" "$INSTALL_APP"
    "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi
"$LSREGISTER" -u "$APP_DIR" >/dev/null 2>&1 || true

swift - >/dev/null 2>&1 <<'SWIFT' || true
import CoreServices
import Foundation

let bundleID = "dev.codex.md2" as NSString
for contentType in ["net.daringfireball.markdown", "public.markdown"] {
    LSSetDefaultRoleHandlerForContentType(contentType as NSString, LSRolesMask.editor, bundleID)
}
SWIFT

echo "Built $APP_DIR"
if [ -z "${CI:-}" ]; then
    echo "Installed $INSTALL_APP"
fi
