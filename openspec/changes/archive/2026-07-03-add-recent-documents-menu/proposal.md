## Why

The File menu replaces the standard new/open command group with custom New and Open items, which removes macOS's built-in "Open Recent" submenu — and the app never records recent documents anywhere. Reopening yesterday's note means walking the open panel or Finder every time. Recent-files access is a core macOS convention (File menu and Dock menu) that every document editor is expected to provide.

## What Changes

- Every successful open and first save of a document records it with the system recent-documents list (`NSDocumentController`), which persists across launches and feeds the Dock icon's recent-items section.
- The File menu gains an "Open Recent" submenu listing recent Markdown documents (most recent first, deduplicated), with a "Clear Menu" item, localized in English and Simplified Chinese.
- Choosing a recent document opens it through the existing open path: an already-open file fronts its window; otherwise a reusable starter window or a new window is used.
- A recent entry whose file no longer exists is handled gracefully: a localized notice, and the entry is dropped from the list.

## Capabilities

### New Capabilities
- `recent-documents`: Recording recently opened/saved documents and reopening them from a localized File ▸ Open Recent submenu that persists across launches.

### Modified Capabilities

## Impact

- `Sources/MD2App/MD2AppDelegate.swift`: note recent URLs on open and save; expose the open path for menu selection.
- `Sources/MD2App/MD2App.swift`: "Open Recent" submenu in the custom `.newItem` command group, rebuilt from `NSDocumentController.shared.recentDocumentURLs`.
- `Sources/MD2App/DocumentStore.swift`: signal successful first-save so the delegate can record it.
- `Sources/MD2App/AppSettings.swift`: `L10nKey` entries for "Open Recent" and "Clear Menu".
- Tests: recording/dedup/missing-file pruning logic factored behind a small injectable recorder.
