## Why

In Side by Side, live updates go into the page with `__md2ApplyContent` and never reach the page `MemoryDocumentSchemeHandler` serves, which stays the HTML of the last full load. So the Reload in the web view's context menu puts the preview back on older text while `Coordinator.lastHTML` says the newest text is showing. Nothing corrects it until the next edit.

That page has no source-line label either. A Reload's navigation is never `currentNavigation`, so `didCommit` skips it, and `pageRevision` still says the old page's label is in place. Clicks on its checkboxes are refused, so no task gets toggled wrongly, but none can be toggled at all. This happens after any Reload, with or without an edit.

`finish-preview-load-on-latest-page` listed the stale text as a non-goal and left it for this change.

## What Changes

- **A Reload is a load of the latest HTML.** `decidePolicyFor` cancels a main-frame `.reload` and starts a real full load of `lastHTML`, before the link router sees it. That navigation is `currentNavigation`, so the page is labelled at commit, and an edit during it takes the path any load gives it.
- **It keeps the reader's place.** WebKit's Reload restores the place of a page the user scrolled, and a load starts at the top. So the place is captured first and goes on as the pending scroll target.
- **The next live update keeps its blocks.** The load records the body it was given, so the first update can key the new page's nodes rather than replace them all.
- **The search comes back.** The marks are in the page, so a query that is open runs again on the new page, and the find bar's count stays true.
- **Tests**, in `PreviewTaskToggleGUITests`: each of the above, a Reload with no edit, and a Reload while a load is held at its policy decision.

**Non-goals:**

- Removing Reload from the context menu. That was rejected in `finish-preview-load-on-latest-page`, since it takes a menu item away to simplify a check.
- Replacing `isAwaitingCommit` with a plain `navigation === currentNavigation` check, which a Reload no longer stands in the way of. The flag is correct as it is.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `split-view-editing`: a Reload in the preview shows the newest text, and it no longer counts as a navigation no load started.

## Impact

- `Sources/MD2App/MarkdownPreviewView.swift`: `decidePolicyFor` and a new `reloadLatestContent(in:)` on the coordinator.
- `Tests/MD2CoreTests/PreviewTaskToggleGUITests.swift`: the Reload tests, a `reload()` helper and a find query on `HeldPreview`.
- No change to rendered HTML or exports: the PDF exporter has its own web view and delegate.
