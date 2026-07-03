## Context

`DocumentStore` owns one document per window. Loading reads the file once (`load(from:)` → `setDocumentText`); saving writes atomically and clears `isDirty`; autosave fires 5 s after the last edit for file-backed documents. Nothing observes the file afterwards: no `NSFilePresenter`, no dispatch source, no modification-date check before writing. The app is not sandboxed and does not use `NSDocument`, so we get none of AppKit's built-in presenters for free. Multiple windows can host different files; the same file is deduped to one window by the app delegate.

## Goals / Non-Goals

**Goals:**
- Detect external content change, deletion, and replacement (editors that write-rename, like vim/atomic saves, replace the inode) for every file-backed window.
- Never silently overwrite external changes; never silently discard the user's unsaved edits.
- Clean documents follow the disk automatically; dirty documents get a clear, localized choice.
- Keep the decision logic pure and unit-testable; keep the watcher a thin, injectable adapter.

**Non-Goals:**
- No three-way merge or diff UI; the conflict choice is reload-or-keep.
- No watching of untitled documents, the bibliography `.bib`, or linked images (existing behavior unchanged).
- No adoption of `NSDocument`/`UIDocument`; the change stays within the current architecture.

## Decisions

- **Watch with a `DispatchSource.makeFileSystemObjectSource` on an `O_EVTONLY` descriptor, re-armed after rename/delete.** Events: `.write`, `.rename`, `.delete`, `.attrib`. Atomic-save editors replace the file, delivering `.rename`/`.delete` on the old inode; the watcher closes the stale descriptor and retries opening the path (short delay, a few attempts) — success means "replaced" (treat as modified), persistent failure means "deleted/moved". Alternative considered: `NSFilePresenter`/`NSFileCoordinator` — rejected: presenters are unreliable without coordinated writers on the other side and drag in coordination requirements for all our own IO; an event source plus fingerprint check is smaller and testable.
- **Fingerprint = modification date + SHA-256 of the bytes this app last read or wrote.** Kept in `DocumentStore`, updated in `setDocumentText` and `write(to:)`. An event (or a pre-write check) reads the current date first and only hashes when the date differs; equal hashes (e.g. our own atomic save's rename event, or a touch without content change) are ignored. This makes the app's own writes self-recognizing without event-suppression races.
- **Debounce watcher events (~200 ms) and evaluate on the main actor**: burst-writes from editors coalesce; evaluation compares the fingerprint, then branches on `isDirty`. Clean → reload in place: capture the live viewport anchor of the active surface (reusing the mode-switch anchor machinery), run the normal load path, re-apply the anchor; `documentIdentity` intentionally stays unchanged so the window does not reset mode/find (requires splitting "reset UI" from "content replaced" in the load path — reload uses a variant that keeps identity).
- **Dirty + external change → conflict state, not an immediate destructive choice.** The store enters `hasExternalConflict`; autosave is suspended while set; a localized `NSAlert` on the affected window offers "Reload from Disk" (discard my edits) and "Keep My Version" (conflict cleared; next save overwrites). Manual ⌘S while in conflict re-presents the same prompt rather than writing blind. Alternative considered: last-writer-wins with a backup copy — rejected: surprising, and backup files pollute the user's directory.
- **Every write checks the fingerprint first.** `write(to:)` compares the on-disk modification date/hash against the last-known fingerprint; mismatch aborts the write and raises the conflict flow. This closes the race where a change lands between watcher event delivery and the autosave timer firing.
- **Deletion/move keeps the user's text and marks the document dirty** (`isDirty = true`, watcher keeps retrying the path), so window-close protection applies and the title reflects unsaved state. The next save recreates the file at the original path and re-arms the watcher. No modal alert for deletion alone — a deleted-but-clean document losing its window silently would be worse than a dirty marker, and the marker is truthful: memory is now the only copy.

## Risks / Trade-offs

- [Found during implementation] Reloading the preview by loading the *same* temp-file URL with only a fragment appended is treated by WebKit as a same-document navigation: it scrolls but never re-reads the file and never fires `didFinish`, so the reloaded content was not displayed. Fixed by appending a monotonic per-load query token to every preview load request so consecutive loads are always real navigations (the link policy compares by path, so the token does not affect it).

- [Hashing large documents on every event could stall the main thread] → hash off-main (the bytes are read on a utility queue; only the decision hops to the main actor); documents are text files, typically well under a few MB.
- [Editors that touch metadata only (`.attrib`) would trigger needless reloads] → fingerprint hash comparison filters no-op events.
- [Reload-in-place while the user is mid-scroll or mid-find in preview] → reload preserves the viewport anchor; find state is rebuilt against the new text by the existing find pipeline (match indices may shift — acceptable and truthful).
- [Watcher descriptor leaks across window close] → the source is cancelled in the store's teardown path (window close removes the `DocumentWindow`, releasing the store); covered by a test asserting cancel on release.
- [Our own atomic saves produce rename events] → self-writes update the fingerprint before the event arrives; equal-hash events are ignored. A regression test simulates write → event.

## Open Questions

- None blocking. If iCloud/network volumes prove event-unreliable later, a low-frequency mtime poll can back up the dispatch source without changing the spec.
