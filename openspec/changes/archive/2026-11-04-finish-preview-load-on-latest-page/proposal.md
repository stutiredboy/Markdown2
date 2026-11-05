## Why

`webView(_:didFinish:)` marks the preview loaded for any navigation, even one a newer `beginLoading()` has superseded. A full load rewrites its HTML off the main thread before it navigates, so the older page's `didFinish` can arrive in that window. `isLoaded` then goes true early, and an edit made before the new page commits takes the live path in `updateNSView` and goes into the old page. The load then commits with older text, and the preview shows stale content until the next edit.

Since `refuse-stale-task-toggles`, that page also carries the newer source-line revision, so a click on it could pass as current. That change listed this race as a known gap in its design.

The same early finish spends work meant for the new page. Typography, the pending scroll target and the pending search run against a page about to go, and the scroll target and the search are gone when the page that matters arrives.

## What Changes

- **Only the page a load asked for ends it.** From `beginLoading` until the latest load's page commits, a page that finishes is ignored: `isLoaded` stays false, and typography, the pending scroll and the pending find wait for that page to finish.
- **An edit during a load gets a load of its own.** This needs no new code. With `isLoaded` false, `updateNSView` already takes the full-load path, which supersedes the load on its way, so the page that lands has the newest text and the label that goes with it.
- **A reload no load started still finishes.** The web view's context menu has a Reload, and its navigation is not `currentNavigation`. It finishes as it does today.
- **Tests**, in `PreviewTaskToggleGUITests`:
  - The race in full through `updateNSView`, with a real load held at its policy decision, so the older text really does land when the fix is missing.
  - The older page finishing while the load is still being prepared, with typography, a scroll target and a search pending.
  - A reload no load started.

**Non-goals:**

- A reload still shows the HTML of the last full load, without the live updates since. That predates this change and is separate from it: nothing here makes it better or worse.
- A load that fails still leaves the preview unloaded until the next edit, as it does today.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `split-view-editing`: a preview load ends only with its own page, so an edit during a load reaches the preview.

## Impact

- `Sources/MD2App/MarkdownPreviewView.swift`: `isAwaitingCommit`, set in `beginLoading`, cleared when `currentNavigation` commits, and read in `webView(_:didFinish:)`.
- `Tests/MD2CoreTests/PreviewTaskToggleGUITests.swift`: the three tests and `NavigationGate`.
- No change to rendered HTML or exports. A load nothing supersedes behaves as before.
