#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_MARKDOWN="${MARKDOWN2_TEST_MARKDOWN:-$ROOT_DIR/Examples/Sample.md}"
DEFAULTS_DIR="$(mktemp -d -t md2-defaults.XXXXXX)"
DEFAULT_DOMAINS=("dev.codex.md2" "dev.codex.md2.debug")
cd "$ROOT_DIR"

cleanup() {
    pkill -x Markdown2 2>/dev/null || true
}

backup_test_defaults() {
    local domain
    for domain in "${DEFAULT_DOMAINS[@]}"; do
        if defaults export "$domain" "$DEFAULTS_DIR/$domain.plist" >/dev/null 2>&1; then
            touch "$DEFAULTS_DIR/$domain.exists"
        fi
    done
}

configure_test_defaults() {
    local domain
    for domain in "${DEFAULT_DOMAINS[@]}"; do
        defaults write "$domain" MD2.Language -string english
        defaults write "$domain" MD2.DefaultMode -string write
        defaults write "$domain" MD2.ShowsOutlineByDefault -bool true
        defaults write "$domain" MD2.OpensBlankDocumentOnLaunch -bool true
    done
}

restore_test_defaults() {
    local domain
    for domain in "${DEFAULT_DOMAINS[@]}"; do
        if [[ -f "$DEFAULTS_DIR/$domain.exists" ]]; then
            defaults import "$domain" "$DEFAULTS_DIR/$domain.plist" >/dev/null 2>&1 || true
        else
            defaults delete "$domain" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$DEFAULTS_DIR"
}

replace_editor_text() {
    local replacement="$1"

    osascript <<APPLESCRIPT
set the clipboard to "$replacement"
tell application "Markdown2" to activate
delay 0.6
tell application "System Events"
    tell process "Markdown2"
        set frontmost to true
        keystroke "a" using {command down}
        delay 0.2
        keystroke "v" using {command down}
    end tell
end tell
APPLESCRIPT
}

assert_file_contains() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    if ! rg -q "$pattern" "$file"; then
        echo "FAIL: $label did not write expected content to $file." >&2
        cat "$file" >&2 || true
        return 1
    fi

    echo "PASS: $label wrote expected content."
}

assert_unsaved_prompt() {
    local result
    result="$(osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Markdown2"
        repeat 20 times
            repeat with candidateWindow in windows
                if exists button "Don't Save" of candidateWindow then
                    return "found"
                end if
                if exists sheet 1 of candidateWindow then
                    if exists button "Don't Save" of sheet 1 of candidateWindow then
                        return "found"
                    end if
                end if
            end repeat
            delay 0.2
        end repeat
    end tell
end tell
return "missing"
APPLESCRIPT
)"

    if [[ "$result" != "found" ]]; then
        echo "FAIL: unsaved quit did not show the save confirmation prompt." >&2
        return 1
    fi

    echo "PASS: unsaved quit showed the save confirmation prompt."
}

dismiss_unsaved_prompt() {
    osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
    tell process "Markdown2"
        repeat with candidateWindow in windows
            if exists button "Don't Save" of candidateWindow then
                click button "Don't Save" of candidateWindow
                return
            end if
            if exists sheet 1 of candidateWindow then
                if exists button "Don't Save" of sheet 1 of candidateWindow then
                    click button "Don't Save" of sheet 1 of candidateWindow
                    return
                end if
            end if
        end repeat
    end tell
end tell
APPLESCRIPT
}

trap 'cleanup; restore_test_defaults' EXIT

backup_test_defaults
configure_test_defaults

frontmost_app() {
    osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
}

assert_frontmost_md2() {
    local label="$1"
    local front
    front="$(frontmost_app)"

    if [[ "$front" != "Markdown2" ]]; then
        echo "FAIL: $label did not activate Markdown2; frontmost app is '$front'." >&2
        return 1
    fi

    echo "PASS: $label activated Markdown2."
}

assert_md2_visible() {
    local label="$1"
    local visible
    visible="$(osascript -e 'tell application "System Events" to tell process "Markdown2" to get visible' 2>/dev/null || echo false)"

    if [[ "$visible" != "true" ]]; then
        echo "FAIL: $label did not create a visible Markdown2 process." >&2
        return 1
    fi

    echo "PASS: $label created a visible Markdown2 process."
}

assert_health_file() {
    local label="$1"
    local health_file="$2"

    if ! rg -q 'visible=[1-9]' "$health_file"; then
        echo "FAIL: $label did not report a visible window." >&2
        cat "$health_file" >&2 || true
        return 1
    fi

    echo "PASS: $label reported a visible window."
}

cleanup

echo "== Unit tests =="
swift test

echo "== Release build =="
swift build -c release --product Markdown2

echo "== App bundle =="
Scripts/package_app.sh
plutil -lint dist/Markdown2.app/Contents/Info.plist
test -x dist/Markdown2.app/Contents/MacOS/Markdown2
test -f dist/Markdown2.app/Contents/Resources/AppIcon.icns
plutil -p dist/Markdown2.app/Contents/Info.plist | rg -q 'CFBundleIconFile|LSItemContentTypes|net.daringfireball.markdown'
handler="$(swift - <<'SWIFT'
import CoreServices
import Foundation

let contentType = "net.daringfireball.markdown" as NSString
let handler = LSCopyDefaultRoleHandlerForContentType(contentType, LSRolesMask.editor)?.takeRetainedValue() as String?
print(handler ?? "")
SWIFT
)"
if [[ "$handler" != "dev.codex.md2" ]]; then
    echo "FAIL: Markdown default editor handler is '$handler', expected 'dev.codex.md2'." >&2
    exit 1
fi

echo "== swift run launch =="
health_file="/tmp/md2-functional-health.txt"
rm -f "$health_file"
MD2_HEALTH_FILE="$health_file" swift run Markdown2 "$TARGET_MARKDOWN" >/tmp/md2-functional-swift-run.log 2>&1 &
runner_pid=$!
sleep 10
assert_md2_visible "swift run"
assert_health_file "swift run" "$health_file"
if kill -0 "$runner_pid" 2>/dev/null; then
    echo "FAIL: swift run launcher should exit after handing off to the app bundle." >&2
    exit 1
fi
cleanup
sleep 1

echo "== dist app launch =="
rm -f "$health_file"
MD2_HEALTH_FILE="$health_file" "$ROOT_DIR/dist/Markdown2.app/Contents/MacOS/Markdown2" "$TARGET_MARKDOWN" >/tmp/md2-functional-dist.log 2>&1 &
dist_pid=$!
sleep 5
assert_md2_visible "dist/Markdown2.app"
assert_health_file "dist/MD2.app" "$health_file"
kill "$dist_pid" 2>/dev/null || true
cleanup

echo "== autosave existing document =="
autosave_file="$(mktemp -t md2-autosave.XXXXXX).md"
printf '# Autosave\n\nOriginal\n' > "$autosave_file"
rm -f "$health_file"
MD2_HEALTH_FILE="$health_file" "$ROOT_DIR/dist/Markdown2.app/Contents/MacOS/Markdown2" "$autosave_file" >/tmp/md2-functional-autosave.log 2>&1 &
sleep 5
assert_md2_visible "autosave app"
assert_health_file "autosave app" "$health_file"
replace_editor_text "# Autosave

Modified by functional test
"
sleep 7
assert_file_contains "autosave" "$autosave_file" "Modified by functional test"
cleanup
sleep 1

echo "== unsaved quit confirmation =="
rm -f "$health_file"
MD2_HEALTH_FILE="$health_file" "$ROOT_DIR/dist/Markdown2.app/Contents/MacOS/Markdown2" >/tmp/md2-functional-unsaved.log 2>&1 &
sleep 5
assert_md2_visible "unsaved app"
assert_health_file "unsaved app" "$health_file"
replace_editor_text "# Unsaved

Dirty draft
"
osascript <<'APPLESCRIPT'
tell application "Markdown2" to activate
delay 0.4
tell application "System Events"
    tell process "Markdown2"
        set frontmost to true
        keystroke "q" using {command down}
    end tell
end tell
APPLESCRIPT
assert_unsaved_prompt
dismiss_unsaved_prompt
sleep 1
cleanup

echo "All functional checks passed."
