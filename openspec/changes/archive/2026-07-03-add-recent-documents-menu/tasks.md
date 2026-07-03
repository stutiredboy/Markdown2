## 1. Recording

- [x] 1.1 Add a small injectable recent-documents recorder wrapping `NSDocumentController.shared` (`note`, `list`, `clear`, `removeMissing`); unit-test dedup-by-standardized-path, ordering, and missing-file pruning against a fake.
- [x] 1.2 Call the recorder on every successful open path in `MD2AppDelegate` and on first save (store signals the delegate or the delegate observes `fileURL` transitions); bump the delegate's `objectWillChange` so the command tree re-evaluates.

## 2. Menu

- [x] 2.1 Add `L10nKey` cases and EN/zh-Hans strings for "Open Recent" and "Clear Menu".
- [x] 2.2 Build the Open Recent submenu in the custom File command group: display names most-recent-first, parent-folder disambiguation for name collisions, Clear Menu at the bottom; selection routes through the delegate's open-in-window path.
- [x] 2.3 Handle missing files on selection: localized failure notice, prune the dead entry, keep the rest.

## 3. Verification

- [x] 3.1 Run `swift test` and build the app.
- [x] 3.2 Manual pass: open several files (panel, Finder, argument), first-save an untitled document, verify submenu order/updates and Dock recents, relaunch for persistence, front-if-open behavior, Clear Menu, and a deleted file's pruning — in both languages.
