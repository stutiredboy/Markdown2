## Why

A file-backed document is loaded once and never watched: if the file changes on disk (git checkout/pull, another editor, a sync tool), the window keeps showing stale content, and the 5-second debounced autosave — or a manual ⌘S — silently overwrites the external changes with the in-memory text. For users who keep Markdown in git repositories this is a realistic data-loss path. Deleting or moving the file externally is equally invisible: autosave quietly recreates the old path.

## What Changes

- Watch the backing file of every file-backed document window for external modification, deletion, and replacement.
- When the file changes externally and the document has no unsaved edits, reload it in place automatically, preserving the current mode and viewport.
- When the file changes externally and the document has unsaved edits, do not touch the text; surface a conflict prompt letting the user reload from disk (discarding their edits) or keep their version (the next save overwrites).
- Every write (manual save and autosave) verifies the on-disk state still matches the last content this app read or wrote; a mismatch stops a silent overwrite — autosave holds off and raises the conflict prompt instead.
- When the file is deleted or moved externally, keep the user's content in memory, mark the document dirty so close/quit protection applies, and let the next save recreate the file at the original path.
- Reloading from disk goes through the existing document-load path so render, outline, stats, and autosave state stay consistent.

## Capabilities

### New Capabilities
- `document-external-change-handling`: How a document window detects and responds to external modification, deletion, or replacement of its backing file — auto-reload when clean, conflict resolution when dirty, and overwrite protection on every write.

### Modified Capabilities

## Impact

- `Sources/MD2App/DocumentStore.swift`: file watcher lifecycle (attach on load/save, detach on close), last-known content fingerprint (modification date + content hash), reload path preserving viewport, write-time conflict check in `write(to:)` and `autosaveNow()`.
- `Sources/MD2App/MD2AppDelegate.swift` / `ContentView.swift`: conflict prompt presentation (localized), viewport preservation on reload.
- `Sources/MD2App/AppSettings.swift`: new localized strings for the conflict prompt and reload notices.
- Tests: fingerprint comparison, reload/conflict decision logic, and watcher event → action mapping as pure, injectable units.
