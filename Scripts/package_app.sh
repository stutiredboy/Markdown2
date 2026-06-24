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

# Copy SwiftPM resource bundles (e.g. Markdown2_MD2Core.bundle, which carries the
# bundled KaTeX assets) next to the .app root, where the generated `Bundle.module`
# accessor looks (Bundle.main.bundleURL/<name>.bundle). Without this the app falls
# back to a hard-coded local .build path that only exists on the build machine.
RELEASE_BIN_DIR="$(cd "$ROOT_DIR/.build/release" && pwd)"
shopt -s nullglob
for bundle in "$RELEASE_BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP_DIR/$(basename "$bundle")"
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
    <string>14.0</string>
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

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
swift - >/dev/null 2>&1 <<'SWIFT' || true
import CoreServices
import Foundation

let bundleID = "dev.codex.md2" as NSString
for contentType in ["net.daringfireball.markdown", "public.markdown"] {
    LSSetDefaultRoleHandlerForContentType(contentType as NSString, LSRolesMask.editor, bundleID)
}
SWIFT

echo "Built $APP_DIR"
