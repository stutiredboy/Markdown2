## Why

File ▸ Open Recent showed the list as of app launch, while the Dock menu was live, so the two disagreed within a session (audit item F11 in `Docs/Review-2026-10-15.md`). A file opened or saved for the first time did not appear in the File menu, and neither Clear Menu nor pruning a missing entry changed it until the next launch.

This was documented as a limit of the framework, and the July 2026 design named moving the whole menu bar to AppKit as the way to lift it. Measuring it again showed the limit is narrower than that: only what the App body reads is frozen. A view inside the command tree that observes its own model updates while Settings is closed. So the fix is one model and one view, not a new menu bar.

## What Changes

- **Open Recent is live.** Opening a file, a first save, Clear Menu and pruning a missing entry all show in the File menu at once, without a relaunch.
- **The File menu and the Dock menu read one list.** The new `RecentDocumentsModel` publishes the entries, and both menus read them, so they cannot disagree on order or titles.
- **`RecentDocumentsMenu` observes the model itself** instead of taking the entries from the App body.
- **Tests:**
  - `RecentDocumentsMenuGUITests`, a multi-process GUI suite, opens the real File menu in a bundle with its own identifier.
  - Headless `RecentDocumentsModelTests`.

**Non-goals:**

- The menu bar stays SwiftUI. No other command changes.
- What gets recorded, where it is stored and how it is capped do not change.
- `Settings` stays the app's only SwiftUI scene, and `.defaultLaunchBehavior(.suppressed)` and the macOS 15 floor stay.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `recent-documents`: the File submenu serves the live list, as the Dock menu does. The launch-snapshot wording is removed.

## Impact

- `Sources/MD2App/RecentDocuments.swift`: the new `RecentDocumentsModel`.
- `Sources/MD2App/MD2App.swift`: `RecentDocumentsMenu` and its call site.
- `Sources/MD2App/MD2AppDelegate.swift`: the delegate owns the model, and `applicationDockMenu(_:)` reads it.
- `Tests/MD2CoreTests/RecentDocumentsMenuGUITests.swift`, `Tests/MD2CoreTests/RecentDocumentsTests.swift`.
- `CLAUDE.md`: the guard for this path.
- No change to documents, rendering or exports.
