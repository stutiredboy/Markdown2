## Context

A full load goes through `WebDocumentLoader.load`, which puts the prepared page in `MemoryDocumentSchemeHandler` and records its navigation as `currentNavigation`. `didCommit` labels the page of that navigation. In Side by Side, later edits go into the page with `__md2ApplyContent`, and `Coordinator.lastHTML` follows them. The memory page does not.

The Reload in the web view's context menu is WebKit's own (menu item tag 12). It reaches `decidePolicyFor` with `navigationType == .reload`, for the page's URL, so `PreviewLinkRouter` allows it and WebKit serves the memory page. That leaves four things out of step:

- The page shows the last full load's text, while `lastHTML` says the newest text is showing.
- Its navigation is not `currentNavigation`, so `didCommit` does not label it, and `pageRevision` keeps saying the old page's label is in place. This one happens with no edit at all.
- `loadedBody` is `nil` after a live update, so the next update has nothing to key the new page's nodes from, and `updateContent` replaces every block.
- The search marks are gone, while `lastFindQuery` says they are in the page.

## Decisions

### A Reload becomes a load, rather than the memory page keeping up

`decidePolicyFor` cancels a main-frame `.reload` and runs a real load of `lastHTML`. Everything that goes wrong above is something a load already does right. Its navigation is `currentNavigation`, so `didCommit` labels it, and `beginLoading` puts the coordinator in the state where an edit during the load takes the full-load path. No new rule is needed for a navigation no load started, because after this change there is none: all a Reload leaves behind is a cancelled policy decision.

*Alternatives considered:*

- **Keep the served page in step with live updates.** A Reload would still not be a load, so `didCommit` would need a second way to know what revision the served page holds, and the page's label, `loadedBody` and `hasContentInFlight` would each need resetting at a commit that nothing announced. An edit between the Reload and its commit would go into the outgoing page and be lost, which is the race `finish-preview-load-on-latest-page` closed, reopened by another route. It also costs a rewrite of the whole page per update, where the live path rewrites only the body.
- **Intercept the menu item in `PreviewWebView.willOpenMenu`.** It would cover the menu and miss every other way to a Reload. The policy decision is where all of them pass.
- **Remove Reload from the menu.** Rejected in `finish-preview-load-on-latest-page`, for taking a menu item away to simplify a check.

### The check comes before the link router

A Reload asks for the page that is showing. Once a load has its own page URL, that is no longer `documentPageURL`, so the router would answer `.ignore` and the Reload would be cancelled with nothing to replace it. That matters more than it looks: a Reload stops a load still at its policy decision, so the load does not land either, and the preview stays on the older page. `testReloadDuringALoadStillLandsTheNewestText` holds that state with `NavigationGate`, and fails with the check placed after the router.

Ahead of the router there is one rule with no window in it: any Reload starts a load of the newest HTML, which supersedes whatever was on its way.

### The reader's place is carried over

WebKit's Reload restores the place of a page the user has scrolled, and a load starts at the top. Measured through the real menu item after real wheel events: WebKit's Reload came back to the same `scrollY`, so a bare load would have been a regression. `reloadLatestContent` captures the viewport anchor first and hands it on as `pendingScroll`, with its heading as the fragment, which is how a mode switch does it. The capture is asynchronous, but it is bounded by `captureTimeout` and the load uses `lastHTML` as it stands when the capture completes.

A page still loading has no place of its own, so its anchor is dropped and any `pendingScroll` already waiting stands.

The new page reports its position on `load`, before that scroll runs. That report is the top of the page, which is no place the reader went, so it is suppressed the way a full load after an edit suppresses it.

### `isAwaitingCommit` stays

With a Reload now a load, a plain `navigation === currentNavigation` in `didFinish` would work, and the design of `finish-preview-load-on-latest-page` chose the flag only because it would not. The flag is still correct and it does not depend on a Reload being the only foreign navigation, so this change leaves it and only drops the comment that gave the old reason.

## Risks / Trade-offs

- **The place is close, not exact.** It is an anchor on a source line rather than WebKit's stored offset, so the page can land a little away from where it was: 27 pixels in the measurement above, on a page of short paragraphs.
- **An open search scrolls to its first match.** `__md2Find` does that on any new page, and a load's search runs after its scroll. A Reload with a search open therefore ends on the first match rather than the reader's place, as a full load after an edit does.
- **A capture that times out loses the place.** After `captureTimeout` the load goes ahead with no anchor and the page starts at the top. It takes a page whose scripts are blocked for that long.
- **The test harness understates WebKit's Reload.** `keepPinned` runs on animation frames and a window off the screen gets none, so `testReloadKeepsTheReadersPlace` replaces them with a timer, as the gutter tests do. In that harness, after a scripted `scrollTo`, WebKit's own Reload also came back at the top, which looks as if it never keeps the place. The measurement above differs from that one in two ways, the window being on screen and the scrolling being real, and which of them matters was not separated. The test covers the load's restore, not WebKit's.
