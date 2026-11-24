#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_GUI=false
case "${1:-}" in
    "") ;;
    --gui) RUN_GUI=true ;;
    --help|-h)
        echo "Usage: Scripts/functional_test.sh [--gui]"
        echo "Runs isolated tests and builds dist/Markdown2.app; never installs or changes file associations."
        exit 0
        ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then echo "Too many arguments." >&2; exit 1; fi
cd "$ROOT_DIR"

# Keep timing checks separate from other tests, matching the shared CI workflow.
swift test --skip 'P1RegressionTests.renderingYieldsMainActorAndLatestRevisionWins' --skip 'InlineRenderingPerformanceTests' --skip 'SelfContainedHTMLExportTests.exportImageBuilderRunsOffMainActorWhileInputCanContinue' --skip 'BlockRenderingPerformanceTests' --skip 'LiteralReplacementPerformanceTests' --skip 'DispatchSourceFileWatcherTests'
swift test --filter 'InlineRenderingPerformanceTests'
swift test --filter 'BlockRenderingPerformanceTests'
swift test --filter 'LiteralReplacementPerformanceTests'
swift test --filter 'P1RegressionTests.renderingYieldsMainActorAndLatestRevisionWins'
swift test --filter 'SelfContainedHTMLExportTests.exportImageBuilderRunsOffMainActorWhileInputCanContinue'
swift test --filter 'DispatchSourceFileWatcherTests'
python3 -m unittest discover -s Tests/WorkflowTests -p 'test_*.py'

if $RUN_GUI; then
    GUI_LOG="$(mktemp -t md2-gui-tests.XXXXXX)"
    echo "GUI results: $GUI_LOG"
    MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing 2>&1 | tee "$GUI_LOG"
    python3 Scripts/check_test_skips.py "$GUI_LOG" .github/gui-expected-skips.txt
fi

# Development bundle identity keeps settings and recovery separate from releases.
bash Scripts/package_app.sh
plutil -lint dist/Markdown2.app/Contents/Info.plist
codesign --verify --deep --strict dist/Markdown2.app
test -x dist/Markdown2.app/Contents/MacOS/Markdown2
test -f dist/Markdown2.app/Contents/Resources/AppIcon.icns
test -d dist/Markdown2.app/Contents/Resources/MD2_MD2Core.bundle
python3 - dist/Markdown2.app/Contents/Info.plist <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    bundle = plistlib.load(stream)
assert bundle["CFBundleIdentifier"] == "dev.codex.md2.development"
markdown, aliases, plain = bundle["CFBundleDocumentTypes"]
assert markdown["LSItemContentTypes"] == ["net.daringfireball.markdown", "public.markdown"]
assert aliases["CFBundleTypeExtensions"] == ["mdown", "mkd"] and "LSItemContentTypes" not in aliases
assert plain["LSItemContentTypes"] == ["public.plain-text"]
assert all(entry["LSHandlerRank"] == "Alternate" for entry in (markdown, aliases, plain))
PY
echo "Local verification passed. Package: dist/Markdown2.app"
