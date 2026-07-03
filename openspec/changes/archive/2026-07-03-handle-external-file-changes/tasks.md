## 1. Fingerprint and Decision Core

- [x] 1.1 Add a content fingerprint (modification date + SHA-256) recorded on load and on every write in `DocumentStore`; expose a pure comparison helper (`unchanged` / `contentChanged` / `missing`).
- [x] 1.2 Add a pure decision unit mapping (watcher event, fingerprint result, `isDirty`) → action (`ignore`, `reloadPreservingViewport`, `presentConflict`, `markDeletedDirty`), with unit tests for own-write events, metadata-only touches, external edits clean/dirty, replacement, and deletion.

## 2. File Watcher

- [x] 2.1 Add an injectable file watcher (DispatchSource on `O_EVTONLY` fd; `.write/.rename/.delete/.attrib`) that debounces bursts, re-arms across atomic-save replacement, retries the path after rename/delete to distinguish replaced vs. deleted, and cancels cleanly on release.
- [x] 2.2 Attach the watcher on document load and first save; detach on window close; verify no descriptor leak (test the cancel path).

## 3. Store Integration

- [x] 3.1 Add a reload-in-place path that reuses the load pipeline but preserves `documentIdentity`, captures the active surface's viewport anchor before replacing text, and re-applies it after render.
- [x] 3.2 Add `hasExternalConflict` state: suspend autosave while set; route manual save during conflict into the prompt instead of writing.
- [x] 3.3 Add the pre-write fingerprint check to `write(to:)`/`autosaveNow()` so a mismatch aborts the write and raises conflict handling.
- [x] 3.4 Handle deletion: mark dirty, keep watching the path, recreate on next save and re-arm the watcher.

## 4. UI and Localization

- [x] 4.1 Present the conflict prompt (localized: title, message, "Reload from Disk", "Keep My Version") on the affected window; wire both outcomes.
- [x] 4.2 Add the new `L10nKey` entries with English and Simplified Chinese strings.

## 5. Verification

- [x] 5.1 Run `swift test`; add store-level tests using the injectable watcher to simulate each spec scenario (own write, clean external edit, dirty conflict both outcomes, autosave abort, deletion + re-save).
- [x] 5.2 Manual pass: edit a file in another editor while clean (auto-reload keeps viewport), while dirty (prompt), `git checkout` a different version, delete the file in Finder, and confirm autosave never overwrites an external change.
