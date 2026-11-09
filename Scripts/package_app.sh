#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Markdown2"     # SPM product / executable name inside the bundle
DISPLAY_NAME="Markdown2" # CFBundleName and the distributed .app/.dmg file name
APP_DIR="$ROOT_DIR/dist/$DISPLAY_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

usage() {
    cat <<'USAGE'
Usage: Scripts/package_app.sh [--release] [--install /absolute/Name.app] [--set-default]

By default, build only dist/Markdown2.app with a separate development identity.
  --release       Use the distributed application's identity (for CI/releases).
  --install PATH  Explicitly replace/install the app at PATH; its parent must exist.
  --set-default   Also make that installed app the default Markdown editor.
                  Requires --install. Installation is not allowed in CI.
  --help          Show this help without building or changing anything.
USAGE
}

RELEASE_BUILD=false
INSTALL_APP=""
SET_DEFAULT=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE_BUILD=true; shift ;;
        --install)
            if [ "$#" -lt 2 ] || [ -n "$INSTALL_APP" ]; then
                echo "--install requires one absolute .app destination." >&2; exit 1
            fi
            INSTALL_APP="$2"
            shift 2
            ;;
        --set-default) SET_DEFAULT=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if $SET_DEFAULT && [ -z "$INSTALL_APP" ]; then
    echo "--set-default requires --install /absolute/Name.app." >&2; exit 1
fi
if [ -n "$INSTALL_APP" ]; then
    if [ -n "${CI:-}" ]; then
        echo "Installation and default-handler changes are disabled in CI." >&2; exit 1
    fi
    case "$INSTALL_APP" in
        /*.app) ;;
        *) echo "--install must name an absolute .app destination." >&2; exit 1 ;;
    esac
    if [ -L "$INSTALL_APP" ]; then
        echo "--install must not replace a symbolic link." >&2; exit 1
    fi
    INSTALL_PARENT="$(cd "$(dirname "$INSTALL_APP")" && pwd -P)" || exit 1
    INSTALL_APP="$INSTALL_PARENT/$(basename "$INSTALL_APP")"
    if [ "$INSTALL_APP" = "$APP_DIR" ]; then
        echo "The install destination must differ from the dist bundle." >&2; exit 1
    fi
fi

BUNDLE_IDENTIFIER="dev.codex.md2.development"
BUNDLE_NAME="Markdown2 Development"
HANDLER_RANK="Alternate"
if $RELEASE_BUILD; then
    BUNDLE_IDENTIFIER="dev.codex.md2"
    BUNDLE_NAME="$DISPLAY_NAME"
    HANDLER_RANK="Owner"
fi

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
            <string>$HANDLER_RANK</string>
        </dict>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
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

# Packaging alone never installs, unregisters bundles, or changes associations.
echo "Built $APP_DIR ($BUNDLE_IDENTIFIER)"
if [ -z "$INSTALL_APP" ]; then exit 0; fi

# Stage and verify before replacing the explicitly selected installation.
INSTALL_STAGE="$(mktemp -d "$INSTALL_PARENT/.md2-install.XXXXXX")"
restore_install_on_failure() {
    if [ -e "$INSTALL_STAGE/Previous.app" ] && [ ! -e "$INSTALL_APP" ]; then
        mv "$INSTALL_STAGE/Previous.app" "$INSTALL_APP"
    fi
    rm -rf "$INSTALL_STAGE"
}
trap restore_install_on_failure EXIT
ditto "$APP_DIR" "$INSTALL_STAGE/New.app"
codesign --verify --deep --strict "$INSTALL_STAGE/New.app"
if [ -e "$INSTALL_APP" ]; then mv "$INSTALL_APP" "$INSTALL_STAGE/Previous.app"; fi
mv "$INSTALL_STAGE/New.app" "$INSTALL_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$INSTALL_APP"
echo "Installed $INSTALL_APP"

if $SET_DEFAULT; then
MD2_INSTALL_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" swift - <<'SWIFT'
import CoreServices
import Foundation

let bundleID = ProcessInfo.processInfo.environment["MD2_INSTALL_BUNDLE_IDENTIFIER"]! as NSString
for contentType in ["net.daringfireball.markdown", "public.markdown"] {
    let status = LSSetDefaultRoleHandlerForContentType(contentType as NSString, LSRolesMask.editor, bundleID)
    guard status == noErr else {
        fputs("Could not set the default handler for \(contentType): \(status)\n", stderr)
        exit(1)
    }
}
SWIFT
echo "Set $BUNDLE_IDENTIFIER as the default Markdown editor"
fi
