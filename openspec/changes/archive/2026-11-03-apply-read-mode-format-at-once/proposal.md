## Why

A formatting command sent from Read mode, such as Bold or Italic, could switch the window to the editor without formatting anything. `MarkdownEditingGUITests.testFormattingFromReadModeSwitchesToEditorWithoutReplayingInFindFields` failed this way on CI's macOS 15 `gui-tests` job twice: on 2026-11-01 (`fix/first-write-anchor`) and on 2026-11-03 (`feat/incremental-preview-update`, which does not touch this path). The format was still missing after the test's 5 s wait. The test passes locally.

In Read mode the editor is unmounted, so `DocumentStore.requestFormat` published the command and switched to Write. The editor that mounted marked the command consumed in its first `updateNSView`. It applied the command on the next run-loop turn, and only if its text view was first responder by then. The mount asks for focus on that same turn, which does nothing while the text view has no window. So a text view that got its window or its focus a turn later never applied the format, and since the command was already consumed, nothing tried again.

## What Changes

- **A format sent in Read mode is applied at once.** The document's editor session keeps its one text view while the editor is unmounted. `requestFormat` now applies the command to that text view through its own editing path, at the selection it kept, and then switches to Write. Nothing waits for the editor's window or focus. The edit lands on the undo stack and reaches the document through the session, as an undo or a task toggle in Read mode already does.
  - If the document changed without the text view, the session first brings the text view up to date, as mounting an editor would.
  - If the editor was never shown, the session builds the text view first, as a task toggle does.
- **Write and Side by Side are unchanged.** A format there still needs the editor to be first responder, so a format sent while a find field has the keyboard is ignored.
- **Tests:**
  - `MarkdownEditingGUITests`:
    - `testFormattingFromReadModeSwitchesToEditorWithoutReplayingInFindFields` now checks that the format is in the document before the editor has a window. It also checks that the mounted editor does not apply it again.
    - The new `testFormattingFromReadModeSurvivesAnEditorFocusedAfterItMounts` keeps the keyboard away from the editor until its mount has run, which is the order that dropped the format on CI. The old code fails it every time.
  - `DocumentUndoHistoryTests`, which runs headless: a format sent with no editor mounted formats the kept selection and undoes, and it follows a document that changed without the text view.

**Non-goals:**

- What a Read-mode format formats does not change: it is the editor's kept selection, as before.
- No change to how the editor takes focus or applies its viewport anchor when it mounts.

## Capabilities

### New Capabilities

- `editor-formatting-commands`: when a formatting command applies, from Read mode and while editing.

### Modified Capabilities

None.

## Impact

- `Sources/MD2App/DocumentStore.swift`: `requestFormat`'s Read-mode path.
- `Sources/MD2App/MarkdownEditorSession.swift`: the new `applyFormatWhileUnmounted`.
- `Tests/MD2CoreTests/MarkdownEditingGUITests.swift`, `Tests/MD2CoreTests/UndoHistoryTests.swift`.
- In Read mode the document changes, and the preview may start re-rendering, in the moment before the switch to Write.
- No change to rendered HTML or exports.
