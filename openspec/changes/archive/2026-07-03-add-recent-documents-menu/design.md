## Context

The app is not `NSDocument`-based; windows and stores are managed by `MD2AppDelegate`, and the File menu is built with SwiftUI `CommandGroup(replacing: .newItem)`. AppKit only auto-inserts the standard "Open Recent" submenu next to a menu item wired to the `openDocument:` action — the SwiftUI buttons here call delegate methods directly, so no automatic submenu exists and nothing populates the system recent list. `MD2AppDelegate` already re-publishes settings changes so the `.commands` tree re-evaluates for localization.

## Goals / Non-Goals

**Goals:**
- Standard macOS recent-documents behavior: File ▸ Open Recent with Clear Menu, persistence across launches, Dock-menu recents, respecting the system "Recent items" count preference.
- Reuse the existing open-in-window path (dedupe + starter-window reuse) unchanged.
- Localized menu copy consistent with the existing `L10n` table.

**Non-Goals:**
- No custom MRU persistence format of our own (no UserDefaults list to maintain, migrate, or cap).
- No security-scoped bookmarks (app is unsandboxed; plain URLs suffice — noted as a future sandbox concern).
- No pinned/favorite documents.

## Decisions

- **[Revised during implementation] Store recents in a UserDefaults-backed list the app owns; the system recents service is not used at all.** The original decision ("NSDocumentController as the store") failed empirically: macOS persists an app's recent documents through `sharedfilelistd`, which declines writes for unsigned/ad-hoc-signed bundles — exactly how this app is distributed — so `recentDocumentURLs` came back empty on every relaunch. The recorder writes its own `MD2.RecentDocuments` path list (prepend, dedupe by standardized path, capped by `maximumRecentDocumentCount` so the system "Recent items" preference is still respected). Best-effort `noteNewRecentDocumentURL` noting was tried and then removed: within a session it feeds a *second*, system-provided recents section in the Dock menu that duplicates the app's own `applicationDockMenu` section (observed live), while contributing nothing that survives relaunch on ad-hoc builds.
- **[Revised during implementation] File ▸ Open Recent shows the persisted list as of launch; the Dock menu serves the live list.** Every live-refresh strategy for the File submenu was exhausted with evidence on this macOS/SwiftUI combination:
  - SwiftUI-side: a nested command `Menu`'s content closure is never re-invoked after the bar is built; `.id(generation)` on command content is ignored; a top-level `ForEach` keyed by generation does not rebuild either; a post-commit `objectWillChange` republish does not help. Root cause: this app's windows are AppKit windows and its only SwiftUI scene is Settings — while Settings is closed, the App body and `.commands` tree are simply never re-evaluated.
  - AppKit-side: an `NSMenuItem` injected into the File menu persists in the `NSMenu` model (verified by probing at menu-tracking begin) but never appears on screen — the File menu's `delegate` is `SwiftUI.AppKitMainMenuItem`, which reconciles the displayed menu from SwiftUI's frozen command tree on every open, discarding foreign items. Claiming that delegate would break SwiftUI's own items.
  - Resolution: the submenu is a plain SwiftUI `Menu` whose displayed entries are the persisted list at launch — which serves the primary recents use case (reopen last session's documents; files opened mid-session already have windows). The Dock icon menu (`applicationDockMenu(_:)`, a sanctioned app-owned hook rebuilt by AppKit on every right-click) serves the live in-session list. A follow-up change that moves the whole menu bar to AppKit — architecturally consistent with this AppKit-window app — would lift the File-submenu snapshot limitation.
- **Selection routes through `openInNewWindow(_:)`** (exposed on the delegate), inheriting front-if-open and starter-window reuse — identical behavior to the Open panel path, so no new spec surface for window management.
- **Missing files**: on selection, if the URL no longer exists, show the existing localized open-failure alert flow and remove the entry (re-noting the remaining URLs after `clearRecentDocuments`, or simply letting the failed entry age out — decision: actively rebuild without the dead entry so the menu heals immediately).
- **Duplicate-name disambiguation**: when two recents share a file name, append the parent directory (`name — folder`) for those entries only, matching common macOS practice.

## Risks / Trade-offs

- [SwiftUI command menus rebuild lazily; the submenu could lag one interaction behind] → the delegate bumps `objectWillChange` after noting a URL (same mechanism the language switch already uses), which re-evaluates commands immediately; verified in the functional pass.
- [`NSDocumentController` may itself present errors for stale URLs in some paths] → we never call its `open…` APIs, only the list-management APIs, so all opening stays in our code.
- [Very long paths/names bloat the menu] → show display names only, disambiguate minimally; full path available via the standard open-panel workflow.

## Open Questions

- None. If sandboxing arrives, recents will need security-scoped bookmark storage; the recorder seam keeps that localized.
